import 'dart:io';
import 'dart:convert';
import 'package:alkion/data/active_session_draft.dart';
import '../support/screen_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/session/active_session_controller.dart';

Future<FixtureDatabase> _open() async {
  final dir = await Directory.systemTemp.createTemp('alkion-model-');
  final db = await FixtureDatabase.open(dir);
  addTearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  return db;
}

Future<String> _finish(ActiveSessionController c, FixtureDatabase db) async {
  for (final b in c.draft.blocks) {
    await db.execute(
      'INSERT INTO exercises (id,name,is_template) VALUES (?,?,0)',
      [b.exercise.id, b.exercise.name],
    );
  }
  await c.flushPersistence();
  return c.commitFinish(WorkoutRepository.local(db));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('direct fresh builder refuses 100 working sets before generation', () {
    final exercise = Exercise.fromRow({'id': 'limit', 'name': 'Synthetic'});
    expect(
      () => buildBlock(
        resolved: ResolvedSlot(
          exercise: exercise,
          workSets: 100,
          warmupSets: 0,
          repLow: 8,
          repHigh: 12,
          rirLow: 1,
          rirHigh: 1,
        ),
      ),
      throwsA(anything),
    );
  });
  // ── D1: build-model tests ────────────────────────────────────────────────

  test(
    'compound block: suggested = roundTo(base + step, step); warm-up ramp',
    () {
      final ex = Exercise.fromRow({
        'id': 'e',
        'name': 'X',
        'slug': 'x',
        'muscle_group': 'back',
        'compound': 1,
        'plate_step_kg': '2.5',
        'base_weight_kg': '75',
      });
      // no history -> base seed; compound bumps one plate
      final block = buildBlock(
        resolved: ResolvedSlot(
          exercise: ex,
          workSets: 4,
          warmupSets: 2,
          repLow: 6,
          repHigh: 8,
          rirLow: 0,
          rirHigh: 1,
        ),
        lastTopKg: null,
      );
      expect(block.workingSets.length, 4);
      expect(block.warmupSets.length, 2);
      // suggested = roundTo(75 + 2.5, 2.5) = 77.5
      expect(block.workingSets.first.weightKg, 77.5);
      expect(block.warmupSets.first.isWarmup, true);
      // Lock down the warm-up ramp roundTo(suggested*(0.5+0.18*i), step):
      expect(
        block.warmupSets[0].weightKg,
        40.0,
      ); // roundTo(77.5*0.50, 2.5) = 38.75 -> 40.0
      expect(
        block.warmupSets[1].weightKg,
        52.5,
      ); // roundTo(77.5*0.68, 2.5) = 52.7 -> 52.5
    },
  );

  test('isolation block: no bump, lastTopKg seeds instead of base', () {
    final ex = Exercise.fromRow({
      'id': 'e2',
      'name': 'Y',
      'slug': 'y',
      'muscle_group': 'chest',
      'compound': 0,
      'plate_step_kg': '2.5',
      'base_weight_kg': '40',
    });
    // lastTopKg takes precedence over base
    final block = buildBlock(
      resolved: ResolvedSlot(
        exercise: ex,
        workSets: 3,
        warmupSets: 0,
        repLow: 10,
        repHigh: 12,
        rirLow: 1,
        rirHigh: 1,
      ),
      lastTopKg: 50.0,
    );
    expect(block.workingSets.length, 3);
    expect(block.warmupSets.isEmpty, true);
    // isolation: no bump; suggested = roundTo(50.0 + 0, 2.5) = 50.0
    expect(block.workingSets.first.weightKg, 50.0);
  });

  test('no baseWeightKg and no history -> falls back to 20 floor', () {
    final ex = Exercise.fromRow({
      'id': 'e3',
      'name': 'Z',
      'slug': 'z',
      'muscle_group': 'arms',
      'compound': 0,
      'plate_step_kg': '2.5',
    });
    final block = buildBlock(
      resolved: ResolvedSlot(
        exercise: ex,
        workSets: 3,
        warmupSets: 0,
        repLow: 10,
        repHigh: 12,
        rirLow: 1,
        rirHigh: 1,
      ),
      lastTopKg: null,
    );
    // seed = 20 (custom-only floor), no compound bump
    // suggested = roundTo(20 + 0, 2.5) = 20.0
    expect(block.workingSets.first.weightKg, 20.0);
  });

  test('SetState defaults: warmup done=false, isWarmup=true, rir=null', () {
    final ex = Exercise.fromRow({
      'id': 'e',
      'name': 'X',
      'slug': 'x',
      'muscle_group': 'back',
      'compound': 1,
      'plate_step_kg': '2.5',
      'base_weight_kg': '75',
    });
    final block = buildBlock(
      resolved: ResolvedSlot(
        exercise: ex,
        workSets: 2,
        warmupSets: 1,
        repLow: 6,
        repHigh: 8,
        rirLow: 0,
        rirHigh: 1,
      ),
      lastTopKg: null,
    );
    expect(block.warmupSets[0].done, false);
    expect(block.warmupSets[0].isWarmup, true);
    expect(block.warmupSets[0].rir, isNull);
    expect(block.workingSets[0].rir, isNull);
    expect(block.workingSets[0].done, false);
  });

  test('roundTo helper rounds to nearest step', () {
    expect(roundTo(38.75, 2.5), 40.0);
    expect(roundTo(52.7, 2.5), 52.5);
    expect(roundTo(77.5, 2.5), 77.5);
    expect(roundTo(19.0, 2.5), 20.0);
  });

  // ── D7: finish() tests ───────────────────────────────────────────────────

  test(
    'finish persists split label and warm-ups with separate compatibility flags',
    () async {
      final ex = Exercise.fromRow({
        'id': 'ex1',
        'name': 'Bench',
        'slug': 'bench',
        'muscle_group': 'chest',
        'compound': 1,
        'plate_step_kg': '2.5',
        'base_weight_kg': '80',
      });

      final db = await _open();
      final drafts = DraftStore.local(db);
      await drafts.load();
      final controller = ActiveSessionController(draftStore: drafts);
      addTearDown(controller.dispose);
      // Manually seed the draft for the test (bypassing buildFromTemplate which
      // requires a live DB; we test finish() logic directly).
      final resolved = ResolvedSlot(
        exercise: ex,
        workSets: 2,
        warmupSets: 1,
        repLow: 6,
        repHigh: 8,
        rirLow: 0,
        rirHigh: 1,
      );
      final block = buildBlock(resolved: resolved, lastTopKg: null);
      for (final s in block.allSets) {
        s.done = true;
      }
      controller.seedForTest(
        SessionDraft(
          templateId: 'day1',
          name: 'Upper A',
          focus: 'Push',
          startedAt: DateTime.now().subtract(const Duration(minutes: 45)),
          blocks: [block],
        ),
      );

      final sessionId = await _finish(controller, db);
      expect(sessionId, isNotEmpty);
      final session = await db.get('SELECT * FROM sessions WHERE id=?', [
        sessionId,
      ]);
      expect(session['split_label'], 'Upper A · Push');
      final sets = await db.getAll(
        'SELECT * FROM reps_compat1_legacy_local WHERE session_id=? ORDER BY set_number',
        [sessionId],
      );
      expect(sets, hasLength(3));
      final working = sets.where((r) => r['is_warmup'] == 0);
      expect(working.where((r) => r['legacy_local_top'] == 1), hasLength(1));
      expect(sets.every((r) => r['legacy_local_pr'] == 0), isTrue);
      expect(sets.first['is_warmup'], 1);
      // Captured source flags stay separate from compatibility derivations.
      expect(
        sets.every((r) => r['is_top_set'] == 0 && r['is_pr'] == 0),
        isTrue,
      );
      final operation = await db.get(
        'SELECT * FROM operations WHERE target_id=?',
        [sessionId],
      );
      final envelope =
          jsonDecode(
                utf8.decode((operation['input_bytes'] as List).cast<int>()),
              )
              as Map;
      final input = envelope['input'] as Map;
      expect((input['session'] as Map).containsKey('user_id'), isFalse);
      expect(
        (input['sets'] as List).every(
          (r) => !(r as Map).containsKey('user_id'),
        ),
        isTrue,
      );
    },
  );

  test(
    'finish() numbers sets continuously across exercises, in workout order',
    () async {
      final ex1 = Exercise.fromRow({
        'id': 'ex1',
        'name': 'Squat',
        'slug': 'squat',
        'muscle_group': 'legs',
        'compound': 1,
        'plate_step_kg': '5.0',
        'base_weight_kg': '100',
      });
      final ex2 = Exercise.fromRow({
        'id': 'ex2',
        'name': 'Curl',
        'slug': 'curl',
        'muscle_group': 'arms',
        'compound': 0,
        'plate_step_kg': '2.5',
        'base_weight_kg': '20',
      });

      final db = await _open();
      final drafts = DraftStore.local(db);
      await drafts.load();
      final controller = ActiveSessionController(draftStore: drafts);
      addTearDown(controller.dispose);
      final block1 = buildBlock(
        resolved: ResolvedSlot(
          exercise: ex1,
          workSets: 2,
          warmupSets: 0,
          repLow: 5,
          repHigh: 6,
          rirLow: 1,
          rirHigh: 1,
        ),
        lastTopKg: null,
      );
      final block2 = buildBlock(
        resolved: ResolvedSlot(
          exercise: ex2,
          workSets: 2,
          warmupSets: 0,
          repLow: 10,
          repHigh: 12,
          rirLow: 1,
          rirHigh: 1,
        ),
        lastTopKg: null,
      );
      for (final s in [...block1.allSets, ...block2.allSets]) {
        s.done = true;
      }
      controller.seedForTest(
        SessionDraft(
          templateId: null,
          name: 'Custom',
          focus: 'Legs+Arms',
          startedAt: DateTime.now().subtract(const Duration(minutes: 30)),
          blocks: [block1, block2],
        ),
      );

      final id = await _finish(controller, db);
      final sets = await db.getAll(
        'SELECT * FROM sets WHERE session_id=? AND deleted=0 ORDER BY set_number',
        [id],
      );
      expect(sets, hasLength(4));
      expect(sets.map((r) => r['exercise_id']), ['ex1', 'ex1', 'ex2', 'ex2']);
      expect(sets.map((r) => r['set_number']), [1, 2, 3, 4]);
    },
  );
}
