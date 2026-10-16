import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'dart:io';
import '../support/screen_harness.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/util/dates.dart';

import '../support/fake_stores.dart';

FinishedSession fin({
  String id = 'S',
  String date = '2026-09-23',
  DateTime? at,
}) => FinishedSession(
  sessionId: id,
  sessionDate: date,
  finishedAt: at ?? DateTime(2026, 9, 23, 10, 0),
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

  test(
    'recordFinished adopts and notifies only after persisting the snapshot',
    () async {
      final store = FakeFinishedSessionStore();
      final m = SessionManager(finishedStore: store);
      addTearDown(m.dispose);
      var notifies = 0;
      m.addListener(() => notifies++);
      final f = fin();

      final pending = m.recordFinished(f, now: f.finishedAt);
      expect(m.lastFinished, isNull); // persistence precedes adoption
      await pending;
      expect(notifies, 1);
      expect(store.stored, same(f));
    },
  );

  test(
    'a failed save retains the previous good snapshot and reports failure',
    () async {
      final old = fin(id: 'P', at: DateTime(2026, 9, 23, 9));
      final store = FakeFinishedSessionStore(stored: old);
      final m = SessionManager(finishedStore: store);
      addTearDown(m.dispose);
      await m.loadLastFinished(now: old.finishedAt);
      store.failSave = true;
      await expectLater(
        m.recordFinished(fin(), now: fin().finishedAt),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.stored, same(old));
      expect(store.clearCount, 0);
      expect(m.lastFinished, same(old));
    },
  );

  test(
    'finishing a registered controller alone adopts nothing in the manager',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'alkion-manager-finish-',
      );
      final db = await FixtureDatabase.open(dir);
      final drafts = DraftStore.local(db);
      await drafts.load();
      final m = SessionManager(
        finishedStore: FinishedSessionStore.local(db),
        draftStore: drafts,
      );
      final c = ActiveSessionController(draftStore: drafts)
        ..seedEmpty(name: 'Custom', focus: '');
      try {
        await c.flushPersistence();
        m.register(c);
        await m.flushPersistence();
        await c.commitFinish(WorkoutRepository.local(db));
        expect(c.lastFinished, isNotNull);
        expect(m.lastFinished, isNull);
        expect(m.hasActive, isFalse);
        expect(
          (await FinishedSessionStore.local(db).load())?.sessionId,
          c.lastFinished!.sessionId,
        );
      } finally {
        m.dispose();
        c.dispose();
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test('loadLastFinished keeps a resumable snapshot', () async {
    final f = fin();
    final m = SessionManager(
      finishedStore: FakeFinishedSessionStore(stored: f),
    );
    addTearDown(m.dispose);
    await m.loadLastFinished(now: DateTime(2026, 9, 23, 18, 0));
    expect(m.lastFinished?.sessionId, 'S');
  });

  test(
    'loadLastFinished hides an expired snapshot while preserving its evidence',
    () async {
      final store = FakeFinishedSessionStore(stored: fin());
      final m = SessionManager(finishedStore: store);
      addTearDown(m.dispose);
      await m.loadLastFinished(now: DateTime(2026, 9, 25, 8, 0));
      expect(m.lastFinished, isNull);
      expect(store.stored, isNotNull);
      expect(store.clearCount, 0);
    },
  );

  test('loadLastFinished reports a store that throws', () async {
    final m = SessionManager(
      finishedStore: FakeFinishedSessionStore(failLoad: true),
    );
    addTearDown(m.dispose);
    await expectLater(
      m.loadLastFinished(now: DateTime(2026, 9, 23, 10, 5)),
      throwsA(isA<FileSystemException>()),
    );
    expect(m.lastFinished, isNull);
  });

  test('forgetFinished drops only a matching session, and notifies', () async {
    final store = FakeFinishedSessionStore();
    final m = SessionManager(finishedStore: store);
    addTearDown(m.dispose);
    final f = fin();
    await m.recordFinished(f, now: f.finishedAt);
    var notifies = 0;
    m.addListener(() => notifies++);

    await m.forgetFinished('other');
    expect(m.lastFinished, same(f));
    expect(notifies, 0);

    await m.forgetFinished('S');
    await Future<void>.delayed(Duration.zero);
    expect(m.lastFinished, isNull);
    expect(notifies, 1);
    expect(store.stored, isNull);
  });

  testWidgets('the snapshot is forgotten when its window closes', (
    tester,
  ) async {
    final store = FakeFinishedSessionStore();
    final m = SessionManager(finishedStore: store);
    // Finished 23:50 → resumable until 00:50 (grace past midnight).
    final f = fin(date: '2026-09-23', at: DateTime(2026, 9, 23, 23, 50));
    await m.recordFinished(f, now: f.finishedAt);

    await tester.pump(const Duration(minutes: 59));
    expect(m.lastFinished, isNotNull);
    await tester.pump(const Duration(minutes: 2));
    expect(m.lastFinished, isNull);
    expect(store.stored, same(f));
    expect(store.clearCount, 0);
    m.dispose();
  });

  test(
    'back in the foreground, a snapshot whose window closed while asleep is forgotten',
    () async {
      final store = FakeFinishedSessionStore();
      final m = SessionManager(finishedStore: store);
      addTearDown(m.dispose);
      // Adopted "then": its expiry timer is armed for hours, and a suspended
      // device's monotonic clock would not have advanced it.
      final at = DateTime.now().subtract(const Duration(days: 3));
      final f = fin(date: isoDate(at), at: at);
      await m.recordFinished(f, now: f.finishedAt);
      expect(m.lastFinished, same(f));

      m.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(m.lastFinished, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(store.stored, same(f));
      expect(store.clearCount, 0);
    },
  );

  test(
    'back in the foreground, a snapshot still in its window is kept',
    () async {
      final m = SessionManager(finishedStore: FakeFinishedSessionStore());
      addTearDown(m.dispose);
      final at = DateTime.now();
      final f = fin(date: isoDate(at), at: at);
      await m.recordFinished(f, now: f.finishedAt);

      m.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(m.lastFinished, same(f));
    },
  );

  test('tryBeginLaunch refuses a second launch until endLaunch', () {
    final m = SessionManager(finishedStore: FakeFinishedSessionStore());
    addTearDown(m.dispose);
    expect(m.tryBeginLaunch(), isTrue);
    expect(m.launching, isTrue);
    expect(m.tryBeginLaunch(), isFalse);
    m.endLaunch();
    expect(m.launching, isFalse);
    expect(m.tryBeginLaunch(), isTrue);
  });

  test('register refuses a second controller while one is active', () {
    final m = SessionManager(finishedStore: FakeFinishedSessionStore());
    addTearDown(m.dispose);
    final a = ActiveSessionController()..seedEmpty(name: 'A', focus: '');
    final b = ActiveSessionController()..seedEmpty(name: 'B', focus: '');
    m.register(a);
    m.register(a); // re-registering the same controller is harmless
    expect(() => m.register(b), throwsStateError);
  });
}
