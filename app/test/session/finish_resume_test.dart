import 'dart:io';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/data/session_repository.dart';
import '../support/screen_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/util/dates.dart';

class _FailingCommit extends RealZoneDatabase {
  _FailingCommit(super.database, super.zone);
  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction) mutate, {
    StoreToken? expected,
  }) => super.apply(action, (tx) async {
    await mutate(tx);
    throw StateError('commit failed');
  }, expected: expected);
}

SessionDraft draftWith({String? sessionId, String? sessionDate}) {
  final ex = Exercise(
    id: 'bench',
    name: 'Bench',
    slug: 'bench',
    muscleGroup: 'chest',
    compound: true,
    plateStepKg: 2.5,
    isTemplate: false,
  );
  return SessionDraft(
    templateId: 'd1',
    name: 'Upper A',
    focus: 'Push',
    startedAt: DateTime.now().subtract(const Duration(minutes: 40)),
    sessionId: sessionId,
    sessionDate: sessionDate,
    blocks: [
      BlockState(
        exercise: ex,
        resolved: ResolvedSlot(
          exercise: ex,
          workSets: 2,
          warmupSets: 1,
          repLow: 5,
          repHigh: 8,
          rirLow: 1,
          rirHigh: 2,
        ),
        warmupSets: [
          SetState(
            id: 'w1',
            weightKg: 40,
            reps: 8,
            rir: null,
            isWarmup: true,
            done: true,
          ),
        ],
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
            id: 's2',
            weightKg: 100,
            reps: 5,
            rir: 1,
            isWarmup: false,
            done: false,
          ),
        ],
        expanded: true,
        bestKg: 90,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late FixtureDatabase db;
  late DraftStore drafts;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('alkion-finish-resume-');
    db = await FixtureDatabase.open(dir);
    await db.execute(
      'INSERT INTO exercises (id,name,is_template) VALUES (?,?,0)',
      ['bench', 'Bench'],
    );
    await db.execute(
      'INSERT INTO day_templates (id,name,is_template) VALUES (?,?,0)',
      ['d1', 'Upper A'],
    );
    drafts = DraftStore.local(db);
    await drafts.load();
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  Future<ActiveSessionController> controller(SessionDraft draft) async {
    if (draft.sessionId != null) {
      await db.execute(
        'INSERT INTO sessions (id,date,day_template_id,split_label,duration_min) VALUES (?,?,?,?,?)',
        [draft.sessionId, draft.sessionDate, 'd1', 'Upper A', 40],
      );
      final row = (await SessionRepository.local(
        db,
      ).sessionById(draft.sessionId!))!;
      draft = SessionDraft.fromJson(
        draft.toJson()..['localRevision'] = row.localRevision,
      );
    }
    final c = ActiveSessionController(draftStore: drafts)..seedForTest(draft);
    addTearDown(c.dispose);
    await c.flushPersistence();
    return c;
  }

  test(
    'a fresh finish records a durable snapshot of the finished workout',
    () async {
      final c = await controller(draftWith());
      final id = await c.commitFinish(WorkoutRepository.local(db));
      final f = c.lastFinished!;
      expect(f.sessionId, id);
      expect(f.sessionDate, isoDate(DateTime.now()));
      expect(f.elapsedSeconds, inInclusiveRange(40 * 60, 40 * 60 + 5));
      expect(f.draft.sessionId, isNull);
      expect(f.draft.blocks.single.workingSets.map((s) => s.done), [
        true,
        false,
      ]);
      expect(
        (await db.get('SELECT day_template_id FROM sessions WHERE id=?', [
          id,
        ]))['day_template_id'],
        'd1',
      );
      expect(c.hasSession, isFalse);
      expect(await drafts.load(), isNull);
    },
  );

  test('the snapshot is a copy the finished draft cannot change', () async {
    final original = draftWith();
    final c = await controller(original);
    await c.commitFinish(WorkoutRepository.local(db));
    original.blocks.single.workingSets.first.weightKg = 1;
    expect(c.lastFinished!.draft.blocks.single.workingSets.first.weightKg, 100);
  });

  test(
    'a resumed finish revises its existing session on its original date',
    () async {
      final c = await controller(
        draftWith(sessionId: 'S', sessionDate: '2026-09-20'),
      );
      final id = await c.commitFinish(WorkoutRepository.local(db));
      expect(id, 'S');
      final sessions = await db.getAll('SELECT * FROM sessions');
      expect(sessions, hasLength(1));
      expect(sessions.single['id'], 'S');
      expect(sessions.single['date'], '2026-09-20');
      expect(sessions.single['revision'], 2);
      expect(
        (await db.get('SELECT action FROM operations WHERE target_id=?', [
          'S',
        ]))['action'],
        'workoutReplace',
      );
      final sets = await db.getAll(
        'SELECT * FROM sets WHERE deleted=0 ORDER BY set_number',
      );
      expect(sets.map((r) => r['id']), ['w1', 's1']);
      expect(sets.every((r) => r['session_id'] == 'S'), isTrue);
      expect(c.lastFinished!.sessionId, 'S');
      expect(c.lastFinished!.sessionDate, '2026-09-20');
    },
  );

  test('a resumed finish derives its PR against the draft baseline', () async {
    final c = await controller(
      draftWith(sessionId: 'S', sessionDate: '2026-09-20'),
    );
    await c.commitFinish(WorkoutRepository.local(db));
    final top = await db.get(
      'SELECT * FROM reps_compat1_legacy_local WHERE id=?',
      ['s1'],
    );
    expect([top['legacy_local_top'], top['legacy_local_pr']], [1, 1]);
    expect([top['is_top_set'], top['is_pr']], [0, 0]);
  });

  test(
    'a finish that fails after its writes keeps the draft and records no snapshot',
    () async {
      final c = await controller(draftWith());
      final before = await db.store.inventory();
      await expectLater(
        c.commitFinish(WorkoutRepository.local(_FailingCommit(db, db.zone))),
        throwsStateError,
      );
      expect(c.lastFinished, isNull);
      expect(c.hasSession, isTrue);
      expect(c.pendingFinish, isNotNull);
      expect(await db.store.inventory(), before);
      expect(await drafts.load(), isNotNull);
    },
  );

  test('discard records no snapshot', () async {
    final c = await controller(draftWith());
    await c.discard();
    expect(c.lastFinished, isNull);
    expect(await drafts.load(), isNull);
    expect(await db.getAll('SELECT * FROM operations'), isEmpty);
  });
}
