import 'dart:async';

import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart' show UnsavedEditors;
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/ui/set_editor_sheet.dart';
import 'package:alkion/theme/alkion_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/icon_finders.dart';
import '../../support/screen_harness.dart';

/// Production SQLite for every attempt; only the outcome is faulted. Before
/// COMMIT a statement breaks a deferred foreign key, so nothing lands;
/// after COMMIT the landed result is hidden from the caller (uncertain).
class _ApplyFaults implements LocalDatabase {
  _ApplyFaults(this.store, {required this.afterCommit});
  final LocalStore store;
  final bool afterCommit;
  int remaining = 0;
  final actions = <LocalAction>[];

  /// When set, every apply waits for it first.
  Completer<void>? gate;

  @override
  String get profileId => store.profileId;
  @override
  StoreToken get token => store.token;
  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction) mutate, {
    StoreToken? expected,
  }) async {
    actions.add(action);
    await gate?.future;
    final fault = remaining > 0;
    if (fault) remaining--;
    final result = await store.apply(action, (tx) async {
      final value = await mutate(tx);
      if (fault && !afterCommit) {
        await tx.execute('INSERT INTO operation_dependencies VALUES(?,?,?,?)', [
          profileId,
          action.family.name,
          action.operationId,
          'test-missing-dependency',
        ]);
      }
      return value;
    }, expected: expected);
    if (fault) throw StateError('synthetic lost COMMIT result');
    return result;
  }

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) => store.getAll(sql, parameters);
  @override
  Future<Map<String, dynamic>> get(
    String sql, [
    List<Object?> parameters = const [],
  ]) => store.get(sql, parameters);
  @override
  Future<Map<String, dynamic>?> getOptional(
    String sql, [
    List<Object?> parameters = const [],
  ]) => store.getOptional(sql, parameters);
  @override
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) => store.watch(sql, parameters: parameters);
  @override
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead) callback, {
    StoreToken? expected,
  }) => store.readTransaction(callback, expected: expected);
  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) => store.writeTransaction(callback, expected: expected);
}

const exactKg = '80.125000000000000001';

Future<void> _seed(FixtureDatabase d) async {
  await seedExercise(d, 'bench', 'Bench');
  final date = DateTime(2026, 11, 2, 9);
  await d.execute(
    'INSERT INTO sessions (id, user_id, date, split_label, notes, day_template_id, '
    "created_at, duration_min) VALUES ('w', 'u1', '2026-11-02', 'Push', '', NULL, ?, 60)",
    [date.toUtc().toIso8601String()],
  );
  for (final (i, rir) in [(0, 2), (1, 1)]) {
    await d.execute(
      'INSERT INTO sets (id, session_id, exercise_id, user_id, set_number, weight_kg, '
      "reps, rir, is_warmup, is_top_set, is_pr, created_at, updated_at) VALUES (?, 'w', 'bench', 'u1', ?, ?, 5, ?, 0, 0, 0, ?, ?)",
      [
        's$i',
        i + 1,
        exactKg,
        rir,
        date.toUtc().toIso8601String(),
        date.toUtc().toIso8601String(),
      ],
    );
  }
}

void main() {
  setUp(UnsavedEditors.instance.resetForTesting);
  tearDown(UnsavedEditors.instance.resetForTesting);

  for (final afterCommit in [false, true]) {
    final mode = afterCommit ? 'uncertain COMMIT' : 'refused COMMIT';
    testWidgets(
      'History RIR clear after a $mode: closable, retried once on the next '
      'flush, stored as NULL with untouched raw evidence, one row and outbox entry',
      (tester) async {
        final harness = ScreenHarness();
        addTearDown(harness.close);
        await harness.open(tester, seed: _seed);
        late _ApplyFaults fault;
        late SessionRepository repository;
        late ExerciseBlockData block;
        late Exercise exercise;
        late Map<String, dynamic> session;
        late int operations;
        await tester.runAsync(() async {
          final store = harness.database.store;
          fault = _ApplyFaults(store, afterCommit: afterCommit);
          repository = SessionRepository.local(
            RealZoneDatabase(fault, Zone.current),
          );
          block = repository
              .groupIntoBlocks(await repository.setsForSession('w'))
              .single;
          exercise = (await ExerciseRepository.local(store).byId('bench'))!;
          session = await store.get("SELECT * FROM sessions WHERE id='w'");
          operations = (await store.getAll('SELECT * FROM operations')).length;
        });
        setPhone(tester, width: 412);
        await tester.pumpWidget(
          harness.wrap(
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) => SetEditorSheet(
                      block: block,
                      exercise: exercise,
                      sessionId: 'w',
                      sessionRepo: repository,
                      units: harness.units,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await settleReal(tester, ticks: 5);
        await tester.tap(find.byKey(const Key('set-line-s0')));
        await settleReal(tester, ticks: 3);
        // Every attempt fails until the "next flush" below.
        fault.remaining = 1000;
        await tester.tap(find.byKey(const Key('rir-2')));
        await tester.pump(const Duration(milliseconds: 450));
        await settleUntilFound(
          tester,
          find.text('OK'),
          where: 'write-failed dialog',
        );
        await tester.tap(find.text('OK'));
        await settleReal(tester, ticks: 3);
        expect(find.text('Not saved · will retry'), findsOneWidget);
        final original = fault.actions.first;
        // A later edit of another set is queued behind the owed write, not
        // dropped, and is prepared only once that write has landed.
        Future<void> dismissFailure() async {
          // The dialog is shown once per failed state; a retry that fails
          // the same way leaves only the inline note.
          expect(find.text('OK'), findsNothing);
        }

        await tester.tap(find.byKey(const Key('set-line-s1')));
        await settleReal(tester, ticks: 3);
        await dismissFailure();
        await tester.tap(find.byKey(const Key('rir-3')));
        await tester.pump(const Duration(milliseconds: 450));
        await settleReal(tester, ticks: 3);
        await dismissFailure();
        expect(find.text('RIR 3'), findsOneWidget);
        // The sheet can be closed; the owed write stays owed.
        Navigator.of(tester.element(find.byType(SetEditorSheet))).pop();
        await settleReal(tester, ticks: 10);
        expect(find.byType(SetEditorSheet), findsNothing);
        expect(UnsavedEditors.instance.unsaved(), ['history_sets']);
        expect(
          fault.actions.map((a) => a.operationId).toSet(),
          {original.operationId},
          reason: 'every retry keeps the original identity',
        );
        // The next flush lands it, once.
        fault.remaining = 0;
        await tester.runAsync(UnsavedEditors.instance.drainOrThrow);
        expect(UnsavedEditors.instance.unsaved(), isEmpty);
        await tester.runAsync(UnsavedEditors.instance.drainOrThrow);
        await tester.runAsync(() async {
          final store = harness.database.store;
          final rows = await store.getAll(
            "SELECT * FROM sets WHERE session_id='w' ORDER BY id",
          );
          expect(rows, hasLength(2), reason: 'no duplicate row');
          final cleared = rows.first, other = rows.last;
          expect(cleared['rir'], isNull);
          expect(cleared['weight_kg'], exactKg);
          expect(cleared['reps'], 5);
          expect(other['rir'], 3);
          expect(other['weight_kg'], exactKg);
          final after = await store.getAll('SELECT * FROM operations');
          expect(
            after,
            hasLength(operations + 2),
            reason: 'one outbox entry per write',
          );
          final owed = after[after.length - 2];
          expect(owed['operation_id'], original.operationId);
          expect(owed['input_bytes'], original.bytes);
          expect(
            fault.actions.where((a) => a.operationId != original.operationId),
            hasLength(1),
            reason: 'the queued edit is prepared and committed once',
          );
          final workout = await store.get(
            "SELECT * FROM sessions WHERE id='w'",
          );
          expect(
            workout['revision'],
            (session['revision'] as int) + 2,
            reason: 'no revision gap',
          );
        });
        await harness.unmount(tester);
      },
    );
  }

  /// Opens a real History card for session `w` over [fault].
  Future<
    ({
      SessionRepository repository,
      Map<String, dynamic> session,
      int operations,
    })
  >
  openCard(
    WidgetTester tester,
    ScreenHarness harness,
    _ApplyFaults fault,
  ) async {
    late SessionRepository repository;
    late Exercise exercise;
    late Map<String, dynamic> session;
    late int operations;
    await tester.runAsync(() async {
      final store = harness.database.store;
      repository = SessionRepository.local(
        RealZoneDatabase(fault, Zone.current),
      );
      exercise = (await ExerciseRepository.local(store).byId('bench'))!;
      session = await store.get("SELECT * FROM sessions WHERE id='w'");
      operations = (await store.getAll('SELECT * FROM operations')).length;
    });
    setPhone(tester, width: 412, height: 1400);
    await tester.pumpWidget(
      harness.wrap(
        Scaffold(
          body: SingleChildScrollView(
            child: SessionCard(
              session: HistorySessionRow(
                id: 'w',
                localRevision: session['revision'] as int,
                date: '2026-11-02',
                splitLabel: 'Push',
                exerciseCount: 1,
                prCount: 0,
                tonnageKg: 0,
              ),
              catalogMap: {'bench': exercise},
              sessionRepo: repository,
              units: harness.units,
            ),
          ),
        ),
      ),
    );
    await settleReal(tester, ticks: 3);
    await tester.tap(findGlyph(AlkionGlyph.chevronRight).first);
    await settleReal(tester, ticks: 5);
    return (repository: repository, session: session, operations: operations);
  }

  Future<List<Map<String, dynamic>>> rows(
    WidgetTester tester,
    ScreenHarness harness,
    String sql,
  ) async => (await tester.runAsync(() => harness.database.store.getAll(sql)))!;

  Future<void> rir(WidgetTester tester, String set, int chip) async {
    final open =
        tester.widget<AlkionIcon>(find.byKey(Key('set-chevron-$set'))).glyph ==
        AlkionGlyph.chevronDown;
    if (!open) {
      await tester.tap(find.byKey(Key('set-line-$set')));
      await settleReal(tester, ticks: 3);
    }
    await tester.tap(find.byKey(Key('rir-$chip')));
    await tester.pump(const Duration(milliseconds: 450));
    await settleReal(tester, ticks: 3);
  }

  Future<void> closeSheet(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(SetEditorSheet))).pop();
    await settleReal(tester, ticks: 10);
    expect(find.byType(SetEditorSheet), findsNothing);
  }

  testWidgets(
    'reopening History after an owed write: blocked while it fails, then '
    'opened on fresh revisions once it lands; each write lands once',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester, seed: _seed);
      late _ApplyFaults fault;
      await tester.runAsync(() async {
        fault = _ApplyFaults(harness.database.store, afterCommit: false);
      });
      final card = await openCard(tester, harness, fault);
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 5);
      fault.remaining = 1000;
      await rir(tester, 's0', 2);
      await tester.tap(find.text('OK'));
      await settleReal(tester, ticks: 3);
      await closeSheet(tester);
      expect(UnsavedEditors.instance.unsaved(), ['history_sets']);
      final original = fault.actions.first.operationId;

      // Still failing: no second editor opens beside the owed write.
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 5);
      expect(find.byType(SetEditorSheet), findsNothing);
      expect(find.text("Couldn't save"), findsOneWidget);
      expect(
        find.textContaining('Earlier changes in History are not saved yet.'),
        findsOneWidget,
      );
      expect(
        find.text('Discard unsaved changes'),
        findsNothing,
        reason: 'a transient failure offers no discard',
      );
      await tester.tap(find.text('OK'));
      await settleReal(tester, ticks: 3);

      // It lands on the retry before the editor opens on fresh revisions.
      fault.remaining = 0;
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 8);
      expect(find.byType(SetEditorSheet), findsOneWidget);
      expect(UnsavedEditors.instance.unsaved(), ['history_sets']..clear());
      expect(
        find.text('RIR 2'),
        findsNothing,
        reason: 'the landed clear shows',
      );
      await rir(tester, 's1', 4);
      expect(find.text('OK'), findsNothing, reason: 'no conflict');
      await closeSheet(tester);
      final operations = await rows(
        tester,
        harness,
        'SELECT * FROM operations',
      );
      expect(operations, hasLength(card.operations + 2));
      expect(
        operations.where((o) => o['operation_id'] == original),
        hasLength(1),
      );
      final sets = await rows(
        tester,
        harness,
        "SELECT * FROM sets WHERE session_id='w' ORDER BY id",
      );
      expect(sets.map((r) => r['rir']), [null, 4]);
      final workout = (await rows(
        tester,
        harness,
        "SELECT * FROM sessions WHERE id='w'",
      )).single;
      expect(workout['revision'], (card.session['revision'] as int) + 2);
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'a permanent conflict stops retrying; History offers a confirmed discard '
    'that drops only the owed set changes',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester, seed: _seed);
      late _ApplyFaults fault;
      await tester.runAsync(() async {
        fault = _ApplyFaults(harness.database.store, afterCommit: false);
      });
      final card = await openCard(tester, harness, fault);
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 5);
      // Another writer moves the workout on after the sheet read it.
      await tester.runAsync(() async {
        final other = SessionRepository.local(harness.database.store);
        final sets = await other.setsForSession('w');
        final s1 = sets.firstWhere((s) => s.id == 's1');
        await other.commitPrepared(
          other.prepareHistoryEdit('w', s1.workoutRevision!, {
            'mode': 'edit',
            'set': {
              'id': 's1',
              'base': s1.localRevision,
              'fields': {'reps': 6},
            },
          }),
        );
      });
      await rir(tester, 's0', 2);
      expect(find.text('OK'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await settleReal(tester, ticks: 3);
      expect(find.text('Not saved · will retry'), findsNothing);
      expect(
        find.byKey(const Key('history-not-saved-permanent')),
        findsOneWidget,
      );
      // No silent retries: later changes neither reach the store nor
      // show the dialog again.
      final attempts = fault.actions.length;
      await rir(tester, 's1', 3);
      await tester.tap(find.byKey(const Key('set-line-s1')));
      await settleReal(tester, ticks: 3);
      expect(fault.actions, hasLength(attempts));
      expect(find.text('OK'), findsNothing);
      await closeSheet(tester);
      await tester.runAsync(UnsavedEditors.instance.retryOwed);
      expect(fault.actions, hasLength(attempts));
      expect(UnsavedEditors.instance.unsaved(), ['history_sets']);

      // History shows the mapped conflict and the explicit discard.
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 5);
      expect(find.byType(SetEditorSheet), findsNothing);
      expect(
        find.textContaining('This changed since you opened it.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Discard unsaved changes'));
      await settleReal(tester, ticks: 3);
      await tester.tap(find.text('Keep editing'));
      await settleReal(tester, ticks: 3);
      expect(UnsavedEditors.instance.unsaved(), ['history_sets']);
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 5);
      await tester.tap(find.text('Discard unsaved changes'));
      await settleReal(tester, ticks: 3);
      await tester.tap(find.text('Discard'));
      await settleReal(tester, ticks: 3);
      expect(UnsavedEditors.instance.unsaved(), isEmpty);
      final operations = await rows(
        tester,
        harness,
        'SELECT * FROM operations',
      );
      expect(
        operations,
        hasLength(card.operations + 1),
        reason: 'only the other writer landed',
      );
      final sets = await rows(
        tester,
        harness,
        "SELECT * FROM sets WHERE session_id='w' ORDER BY id",
      );
      expect(sets.map((r) => r['rir']), [2, 1]);
      expect(sets.last['reps'], 6);
      // The editor now opens and saves normally.
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 8);
      expect(find.byType(SetEditorSheet), findsOneWidget);
      await rir(tester, 's0', 2);
      expect(find.text('OK'), findsNothing);
      await closeSheet(tester);
      expect(
        (await rows(
          tester,
          harness,
          "SELECT rir FROM sets WHERE id='s0'",
        )).single['rir'],
        isNull,
      );
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'in the sheet a permanent failure offers Discard set changes, which '
    'drops only its own owed changes and closes',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester, seed: _seed);
      late _ApplyFaults fault;
      await tester.runAsync(() async {
        fault = _ApplyFaults(harness.database.store, afterCommit: false);
      });
      final card = await openCard(tester, harness, fault);
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 5);
      await tester.runAsync(() async {
        final other = SessionRepository.local(harness.database.store);
        final s0 = (await other.setsForSession('w')).first;
        await other.commitPrepared(
          other.prepareHistoryEdit('w', s0.workoutRevision!, {
            'mode': 'delete',
            'set': {'id': 's1', 'base': s0.localRevision},
          }),
        );
      });
      // Another History owed write elsewhere is not touched by this discard.
      UnsavedEditors.instance.owe('elsewhere', 'history_delete', () async {
        throw const StoreException('recovery_required');
      });
      await rir(tester, 's0', 2);
      await tester.tap(find.text('OK'));
      await settleReal(tester, ticks: 3);
      await tester.tap(find.byKey(const Key('history-discard-owed')));
      await settleReal(tester, ticks: 3);
      expect(find.text('Discard set changes?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await settleReal(tester, ticks: 10);
      expect(find.byType(SetEditorSheet), findsNothing);
      expect(UnsavedEditors.instance.unsaved(), ['history_delete']);
      final operations = await rows(
        tester,
        harness,
        'SELECT * FROM operations',
      );
      expect(operations, hasLength(card.operations + 1));
      expect(
        (await rows(
          tester,
          harness,
          "SELECT rir FROM sets WHERE id='s0'",
        )).single['rir'],
        2,
      );
      UnsavedEditors.instance.discard('elsewhere');
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'a set without an observed base fails alone; the other sets are written',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester, seed: _seed);
      late SessionRepository repository;
      late ExerciseBlockData block;
      late Exercise exercise;
      late int operations;
      await tester.runAsync(() async {
        final store = harness.database.store;
        repository = SessionRepository.local(
          RealZoneDatabase(store, Zone.current),
        );
        final sets = await repository.setsForSession('w');
        final first = sets.first;
        // A legacy row whose base was never observed.
        final unobserved = LoggedSet(
          id: first.id,
          exerciseId: first.exerciseId,
          setNumber: first.setNumber,
          weightKg: first.weightKg,
          reps: first.reps,
          rir: first.rir,
          isWarmup: false,
          isTopSet: first.isTopSet,
          isPr: false,
          workoutRevision: first.workoutRevision,
        );
        block = repository.groupIntoBlocks([
          unobserved,
          ...sets.skip(1),
        ]).single;
        exercise = (await ExerciseRepository.local(store).byId('bench'))!;
        operations = (await store.getAll('SELECT * FROM operations')).length;
      });
      setPhone(tester, width: 412);
      await tester.pumpWidget(
        harness.wrap(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => SetEditorSheet(
                    block: block,
                    exercise: exercise,
                    sessionId: 'w',
                    sessionRepo: repository,
                    units: harness.units,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settleReal(tester, ticks: 5);
      await rir(tester, 's0', 2);
      await tester.tap(find.text('OK'));
      await settleReal(tester, ticks: 3);
      await rir(tester, 's1', 4);
      final sets = await rows(
        tester,
        harness,
        "SELECT * FROM sets WHERE session_id='w' ORDER BY id",
      );
      expect(sets.map((r) => r['rir']), [2, 4]);
      expect(
        await rows(tester, harness, 'SELECT * FROM operations'),
        hasLength(operations + 1),
      );
      expect(
        find.byKey(const Key('history-not-saved-permanent')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('history-discard-owed')));
      await settleReal(tester, ticks: 3);
      await tester.tap(find.text('Discard'));
      await settleReal(tester, ticks: 10);
      expect(UnsavedEditors.instance.unsaved(), isEmpty);
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'Add set and a confirmed Delete behind a failing owed write are queued '
    'and land in order once it does',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester, seed: _seed);
      late _ApplyFaults fault;
      await tester.runAsync(() async {
        fault = _ApplyFaults(harness.database.store, afterCommit: true);
      });
      final card = await openCard(tester, harness, fault);
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 5);
      fault.remaining = 1000;
      await rir(tester, 's0', 2);
      await tester.tap(find.text('OK'));
      await settleReal(tester, ticks: 3);
      final owed = fault.actions.first.operationId;
      await tester.tap(find.byKey(const Key('add-set')));
      await settleReal(tester, ticks: 3);
      await tester.tap(find.byKey(const Key('set-line-s1')));
      await settleReal(tester, ticks: 3);
      await tester.tap(find.byKey(const Key('delete-set')));
      await settleReal(tester, ticks: 3);
      await tester.tap(find.text('Delete'));
      await settleReal(tester, ticks: 3);
      expect(find.text('OK'), findsNothing, reason: 'shown once per state');
      expect(find.text('Not saved · will retry'), findsOneWidget);
      expect(
        fault.actions.map((a) => a.operationId).toSet(),
        {owed},
        reason: 'nothing newer is prepared before the owed write lands',
      );
      fault.remaining = 0;
      await closeSheet(tester);
      for (
        var i = 0;
        i < 20 && UnsavedEditors.instance.unsaved().isNotEmpty;
        i++
      ) {
        await settleReal(tester, ticks: 2);
      }
      expect(UnsavedEditors.instance.unsaved(), isEmpty);
      final operations = await rows(
        tester,
        harness,
        'SELECT * FROM operations',
      );
      expect(operations, hasLength(card.operations + 3));
      final actions = operations.skip(card.operations).toList();
      expect(actions.first['operation_id'], owed);
      final sets = await rows(
        tester,
        harness,
        "SELECT * FROM sets WHERE session_id='w' AND deleted=0 ORDER BY set_number",
      );
      expect(sets.map((r) => r['id']), ['s0', isNot('s1')]);
      expect(sets.first['rir'], isNull);
      expect(sets.last['rir'], isNull, reason: 'an added set has no RIR');
      final workout = (await rows(
        tester,
        harness,
        "SELECT * FROM sessions WHERE id='w'",
      )).single;
      expect(workout['revision'], (card.session['revision'] as int) + 3);
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'an owed session delete blocks only its own session; a permanent one is '
    'offered a confirmed discard; elsewhere it never blocks',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester, seed: _seed);
      late _ApplyFaults fault;
      await tester.runAsync(() async {
        fault = _ApplyFaults(harness.database.store, afterCommit: false);
      });
      await openCard(tester, harness, fault);
      Future<void> failing(String key, String category) async =>
          throw StoreException(category);
      // A transiently failing delete of another session: retried, not blocking.
      UnsavedEditors.instance.owe(
        'history_delete:1:other-session:3',
        'history_delete',
        () => failing('a', 'recovery_required'),
      );
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 8);
      expect(find.text("Couldn't save"), findsNothing);
      expect(find.byType(SetEditorSheet), findsOneWidget);
      await closeSheet(tester);

      // A permanently failing delete elsewhere: offered once, then editing opens.
      UnsavedEditors.instance.owe(
        'history_delete:1:gone-session:4',
        'history_delete',
        () => failing('b', 'revision_conflict'),
      );
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 5);
      expect(find.text('Discard unsaved changes'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await settleReal(tester, ticks: 8);
      expect(find.byType(SetEditorSheet), findsOneWidget);
      await closeSheet(tester);
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 8);
      expect(find.text('Discard unsaved changes'), findsNothing);
      expect(find.byType(SetEditorSheet), findsOneWidget);
      await closeSheet(tester);

      // A permanently failing delete of this session blocks it until discarded.
      UnsavedEditors.instance.owe(
        'history_delete:1:w:5',
        'history_delete',
        () => failing('c', 'revision_conflict'),
      );
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 5);
      expect(find.byType(SetEditorSheet), findsNothing);
      await tester.tap(find.text('Discard unsaved changes'));
      await settleReal(tester, ticks: 3);
      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await settleReal(tester, ticks: 3);
      expect(
        UnsavedEditors.instance.owed().map((o) => o.key),
        isNot(contains('history_delete:1:w:5')),
      );
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 8);
      expect(find.byType(SetEditorSheet), findsOneWidget);
      await closeSheet(tester);
      expect(fault.actions, isEmpty, reason: 'no History write was attempted');
      await harness.unmount(tester);
    },
  );

  testWidgets('a double tap while owed work is retried opens one editor', (
    tester,
  ) async {
    final harness = ScreenHarness();
    addTearDown(harness.close);
    await harness.open(tester, seed: _seed);
    late _ApplyFaults fault;
    late Completer<void> slow;
    await tester.runAsync(() async {
      fault = _ApplyFaults(harness.database.store, afterCommit: false);
      slow = Completer<void>();
    });
    await openCard(tester, harness, fault);
    UnsavedEditors.instance.owe(
      'history_delete:1:elsewhere:2',
      'history_delete',
      () => slow.future,
    );
    await tester.tap(find.text('Bench'));
    await tester.pump();
    await tester.tap(find.text('Bench'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('history-add-exercise')));
    await tester.pump();
    await tester.runAsync(() async => slow.complete());
    await settleReal(tester, ticks: 10);
    expect(find.byType(SetEditorSheet), findsOneWidget);
    expect(find.text('Add exercise'), findsOneWidget, reason: 'no picker');
    await closeSheet(tester);
    await harness.unmount(tester);
  });

  testWidgets(
    'Add exercise right after a sheet write reads the session revision '
    'fresh and lands without conflict',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester, seed: _seed);
      late _ApplyFaults fault;
      await tester.runAsync(() async {
        fault = _ApplyFaults(harness.database.store, afterCommit: false);
      });
      final card = await openCard(tester, harness, fault);
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 5);
      await rir(tester, 's0', 2);
      await closeSheet(tester);
      // The card still holds the revision it was built with.
      await tester.tap(find.byKey(const ValueKey('history-add-exercise')));
      await settleReal(tester, ticks: 5);
      await tester.tap(find.text('Bench').last);
      await settleReal(tester, ticks: 8);
      expect(find.byType(SetEditorSheet), findsOneWidget);
      await tester.tap(find.byKey(const Key('add-set')));
      await settleReal(tester, ticks: 8);
      expect(find.text('OK'), findsNothing, reason: 'no conflict');
      await closeSheet(tester);
      final operations = await rows(
        tester,
        harness,
        'SELECT * FROM operations',
      );
      expect(operations, hasLength(card.operations + 2));
      expect(
        await rows(
          tester,
          harness,
          "SELECT * FROM sets WHERE session_id='w' AND deleted=0",
        ),
        hasLength(3),
      );
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'an uncertain COMMIT reconciles once, then a permanent conflict behind it '
    'stops and can be discarded without touching the landed write',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester, seed: _seed);
      late _ApplyFaults fault;
      await tester.runAsync(() async {
        fault = _ApplyFaults(harness.database.store, afterCommit: true);
      });
      final card = await openCard(tester, harness, fault);
      await tester.tap(find.text('Bench'));
      await settleReal(tester, ticks: 5);
      fault.remaining = 1;
      await rir(tester, 's0', 2);
      await tester.tap(find.text('OK'));
      await settleReal(tester, ticks: 3);
      expect(find.text('Not saved · will retry'), findsOneWidget);
      final head = fault.actions.single.operationId;
      // Another writer moves the workout on behind the uncertain head.
      await tester.runAsync(() async {
        final other = SessionRepository.local(harness.database.store);
        final s1 = (await other.setsForSession(
          'w',
        )).firstWhere((s) => s.id == 's1');
        await other.commitPrepared(
          other.prepareHistoryEdit('w', s1.workoutRevision!, {
            'mode': 'edit',
            'set': {
              'id': 's1',
              'base': s1.localRevision,
              'fields': {'reps': 6},
            },
          }),
        );
      });
      await rir(tester, 's1', 4);
      // The head replays (reconciled, not rewritten); the edit behind it
      // conflicts for good: shown once more, as a different failure.
      expect(find.text('OK'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await settleReal(tester, ticks: 3);
      expect(
        find.byKey(const Key('history-not-saved-permanent')),
        findsOneWidget,
      );
      expect(fault.actions.where((a) => a.operationId == head), hasLength(2));
      await tester.tap(find.byKey(const Key('history-discard-owed')));
      await settleReal(tester, ticks: 3);
      await tester.tap(find.text('Discard'));
      await settleReal(tester, ticks: 10);
      expect(find.byType(SetEditorSheet), findsNothing);
      expect(UnsavedEditors.instance.unsaved(), isEmpty);
      final operations = await rows(
        tester,
        harness,
        'SELECT * FROM operations',
      );
      expect(operations, hasLength(card.operations + 2));
      expect(operations.where((o) => o['operation_id'] == head), hasLength(1));
      final sets = await rows(
        tester,
        harness,
        "SELECT * FROM sets WHERE session_id='w' ORDER BY id",
      );
      expect(sets.map((r) => r['rir']), [null, 1]);
      expect(sets.last['reps'], 6);
      await harness.unmount(tester);
    },
  );
}
