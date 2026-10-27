import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/store/local_store.dart';

import '../support/screen_harness.dart';

// The production callback writes to the real store before this adapter throws;
// LocalStore must roll the complete transaction back.
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

FinishedSession previous() => FinishedSession(
  sessionId: 'P',
  sessionDate: '2026-09-23',
  finishedAt: DateTime(2026, 9, 23, 10),
  elapsedSeconds: 2400,
  draft: SessionDraft(
    templateId: null,
    name: 'Upper A',
    focus: '',
    startedAt: DateTime(2026, 9, 23, 9, 20),
    blocks: [],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late FixtureDatabase db;
  late DraftStore drafts;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('alkion-finish-');
    db = await FixtureDatabase.open(dir);
    drafts = DraftStore.local(db);
    await drafts.load();
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<ActiveSessionController> controller() async {
    final c = ActiveSessionController(draftStore: drafts)
      ..seedEmpty(name: 'Custom', focus: '');
    addTearDown(c.dispose);
    await c.flushPersistence();
    return c;
  }

  test(
    'a committed finish hands its durable snapshot to the manager',
    () async {
      final store = FinishedSessionStore.local(db);
      final m = SessionManager(finishedStore: store, draftStore: drafts);
      addTearDown(m.dispose);
      final c = await controller();
      m.register(c);
      await m.flushPersistence();
      final id = await finishWorkout(
        c,
        m,
        repository: WorkoutRepository.local(db),
      );
      expect(m.lastFinished, same(c.lastFinished));
      expect(m.lastFinished!.sessionId, id);
      expect((await store.load())?.sessionId, id);
      expect(await drafts.load(), isNull);
      expect(m.hasActive, isFalse);
      expect(
        (await db.get('SELECT action FROM operations WHERE target_id=?', [
          id,
        ]))['action'],
        'workoutFinish',
      );
    },
  );

  test(
    'a failed finish commit keeps the previous snapshot and editable draft',
    () async {
      final p = previous();
      final store = FinishedSessionStore.local(db);
      final m = SessionManager(finishedStore: store, draftStore: drafts);
      addTearDown(m.dispose);
      await m.recordFinished(p, now: p.finishedAt);
      final c = await controller();
      m.register(c);
      await m.flushPersistence();
      final before = await db.store.inventory();
      await expectLater(
        finishWorkout(
          c,
          m,
          repository: WorkoutRepository.local(_FailingCommit(db, db.zone)),
        ),
        throwsStateError,
      );
      expect(await db.store.inventory(), before);
      expect(c.lastFinished, isNull);
      expect(c.pendingFinish, isNotNull);
      expect(c.hasSession, isTrue);
      expect(m.active, same(c));
      expect(m.lastFinished, same(p));
      expect((await store.load())?.toJson(), p.toJson());
      final intent = c.pendingFinish!;
      final id = await finishWorkout(
        c,
        m,
        repository: WorkoutRepository.local(db),
      );
      expect(id, intent.action.target.id);
      expect(
        (await db.getAll(
          'SELECT operation_id FROM operations',
        )).single['operation_id'],
        intent.action.operationId,
      );
    },
  );

  test('concurrent Finish and flushes share one durable completion', () async {
    final m = SessionManager(
      finishedStore: FinishedSessionStore.local(db),
      draftStore: drafts,
    );
    addTearDown(m.dispose);
    final c = await controller();
    m.register(c);
    await m.flushPersistence();
    final repository = WorkoutRepository.local(db);
    // Enter the controller queue before Finish installs its in-flight result.
    final queued = c.flushPersistence();
    final first = finishWorkout(c, m, repository: repository);
    final barrier = m.flushPersistence();
    final second = finishWorkout(c, m, repository: repository);
    final ids = await Future.wait([first, second]);
    await Future.wait([queued, barrier]).timeout(const Duration(seconds: 5));
    expect(ids[1], ids[0]);
    expect(m.lastFinished, same(c.lastFinished));
    expect(m.persistenceError, isNull);
    expect(await db.getAll('SELECT * FROM sessions'), hasLength(1));
    expect(await db.getAll('SELECT * FROM operations'), hasLength(1));
    expect(await drafts.load(), isNull);
  });

  test(
    'failed shared Finish stays pending and retries the original intent',
    () async {
      final m = SessionManager(
        finishedStore: FinishedSessionStore.local(db),
        draftStore: drafts,
      );
      addTearDown(m.dispose);
      final c = await controller();
      m.register(c);
      await m.flushPersistence();
      final before = await db.store.inventory();
      final repository = WorkoutRepository.local(_FailingCommit(db, db.zone));
      Future<Object?> outcome(Future<Object?> work) =>
          work.then<Object?>((_) => null, onError: (Object e) => e);
      final queued = outcome(c.flushPersistence());
      final first = outcome(finishWorkout(c, m, repository: repository));
      final barrier = outcome(m.flushPersistence());
      final second = outcome(finishWorkout(c, m, repository: repository));
      final errors = await Future.wait([
        first,
        barrier,
        second,
        queued,
      ]).timeout(const Duration(seconds: 5));
      expect(errors, everyElement(isA<StateError>()));
      expect(identical(errors[0], errors[2]), isTrue);
      expect(identical(errors[0], errors[3]), isTrue);
      expect(await db.store.inventory(), before);
      final intent = c.pendingFinish!;
      await expectLater(
        m.flushPersistence(),
        throwsA(
          isA<StoreException>().having(
            (e) => e.category,
            'category',
            'finish_retry_required',
          ),
        ),
      );
      final id = await finishWorkout(
        c,
        m,
        repository: WorkoutRepository.local(db),
      );
      expect(id, intent.action.target.id);
      final operation = (await db.getAll('SELECT * FROM operations')).single;
      expect(operation['operation_id'], intent.action.operationId);
      expect(operation['input_hash'], intent.action.hash);
      expect(await drafts.load(), isNull);
    },
  );

  test(
    'without a manager the finish still returns its durable session id',
    () async {
      final c = await controller();
      final id = await finishWorkout(
        c,
        null,
        repository: WorkoutRepository.local(db),
      );
      expect(id, c.lastFinished!.sessionId);
      expect((await FinishedSessionStore.local(db).load())?.sessionId, id);
    },
  );
}
