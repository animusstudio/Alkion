import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/bodyweight_repository.dart';
import 'package:alkion/data/models.dart';
import 'local_screen_harness.dart';

/// Fault forwarding always executes real production SQLite, never fakes success.
class FaultDatabase implements LocalDatabase {
  FaultDatabase(
    this.store, {
    this.beforeCommit = false,
    this.afterCommit = false,
    this.closeRecovery = false,
    this.gate,
  });
  final LocalStore store;
  final bool beforeCommit, afterCommit, closeRecovery;
  final Completer<void>? gate;
  final List<LocalAction> actions = [];
  bool failed = false;
  File? preserved;
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
    final fault = !failed;
    failed = true;
    StreamSubscription<RecoveryPhase>? subscription;
    if (fault && closeRecovery) {
      subscription = store.recoveryEvents.listen((phase) {
        if (phase == RecoveryPhase.poolClosed && preserved == null) {
          preserved = File('${store.path}.test-preserved');
          File(store.path).copySync(preserved!.path);
          File(store.path).writeAsBytesSync([0, 255, 1, 2], flush: true);
        }
      });
    }
    try {
      final result = await store.apply(action, (tx) async {
        final result = await mutate(tx);
        if (fault && (beforeCommit || closeRecovery)) {
          await tx
              .execute('INSERT INTO operation_dependencies VALUES(?,?,?,?)', [
                profileId,
                action.family.name,
                action.operationId,
                'test-missing-dependency',
              ]);
        }
        return result;
      }, expected: expected);
      if (fault && afterCommit) {
        throw StateError('test consumer lost COMMIT result');
      }
      return result;
    } finally {
      await subscription?.cancel();
    }
  }

  Future<void> restorePreserved() async {
    await preserved!.copy(store.path);
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

void main() {
  late Directory root;
  late LocalStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-prepared');
    store = await openDomainStore(root);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  for (final after in [false, true]) {
    test(
      'real repository retains same measurement action after ${after ? 'consumer uncertainty' : 'true COMMIT failure'}',
      () async {
        final fault = FaultDatabase(
              store,
              beforeCommit: !after,
              afterCommit: after,
            ),
            repo = BodyweightRepository.local(fault);
        final intent = repo.prepareMeasurement(
          dateIso: '2026-10-13',
          kg: const DecimalEvidence(ValueState.valid, '82.450000000000000001'),
        );
        await expectLater(repo.commitPrepared(intent), throwsA(anything));
        final result = await repo.commitPrepared(intent);
        expect(result.replayed, after);
        expect(fault.actions.map((a) => a.operationId).toSet(), {
          intent.action.operationId,
        });
        expect(fault.actions.map((a) => a.hash).toSet(), {intent.action.hash});
        expect(
          await store.getAll('SELECT * FROM bodyweight_logs'),
          hasLength(1),
        );
        expect(await store.getAll('SELECT * FROM operations'), hasLength(1));
        final before = await store.inventory();
        await store.close();
        store = await openDomainStore(root);
        expect(await store.inventory(), before);
      },
    );
  }
  test(
    'mutable day/slot draft cannot change prepared bytes or SQL after apply awaits',
    () async {
      await seedExercise(store, 'ex', 'Bench');
      final gate = Completer<void>(), fault = FaultDatabase(store, gate: gate);
      final repo = DayTemplateRepository.local(fault),
          slot = SlotDraft(exerciseId: 'ex', rirLow: 9, rirHigh: -1);
      final draft = DayDraft(name: 'Prepared', slots: [slot]);
      final intent = repo.prepareDay(draft);
      final saving = repo.commitPrepared(intent);
      draft.name = 'Mutated';
      slot.exerciseId = 'foreign';
      slot.rirLow = 0;
      draft.slots.clear();
      gate.complete();
      await saving;
      final day = (await repo.watchDays().first).single;
      expect(day.name, 'Prepared');
      expect(day.slots.single.exerciseId, 'ex');
      expect(day.slots.single.rirLow, 9);
      expect(
        (await store.getAll('SELECT * FROM operations WHERE operation_id=?', [
          intent.action.operationId,
        ])).single['input_bytes'],
        intent.action.bytes,
      );
    },
  );
  test(
    'failed reopen remains closed and repository retries identical intent after explicit owner repair',
    () async {
      final fault = FaultDatabase(store, closeRecovery: true),
          repo = BodyweightRepository.local(fault);
      final intent = repo.prepareMeasurement(
        dateIso: '2026-10-13',
        kg: const DecimalEvidence(ValueState.valid, '82.4500'),
      );
      await expectLater(repo.commitPrepared(intent), throwsA(anything));
      expect(store.admission, StoreAdmission.closed);
      expect(store.pendingRecoveryAction!.bytes, intent.action.bytes);
      await expectLater(
        repo.commitPrepared(intent),
        throwsA(isA<StoreException>()),
      );
      await fault.restorePreserved();
      await store.recover();
      await repo.commitPrepared(intent);
      expect(fault.actions.map((a) => a.hash).toSet(), {intent.action.hash});
      expect(await store.getAll('SELECT * FROM bodyweight_logs'), hasLength(1));
    },
  );
}
