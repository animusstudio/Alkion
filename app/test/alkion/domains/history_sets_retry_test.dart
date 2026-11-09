import 'dart:async';

import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart' show UnsavedEditors;
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/set_editor_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
          // Each retry that fails again is shown again.
          if (find.text('OK').evaluate().isNotEmpty) {
            await tester.tap(find.text('OK'));
            await settleReal(tester, ticks: 3);
          }
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
}
