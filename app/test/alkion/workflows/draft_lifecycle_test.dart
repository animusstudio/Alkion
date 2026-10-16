import 'package:alkion/session/session_manager.dart';
import 'package:alkion/data/finished_session_store.dart';
import '../../../tool/alkion_store_recovery.dart' show workflowDraft;
import 'resume_history_test.dart' show archiveOwned, checkpoint, seed;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import '../domains/local_screen_harness.dart' show RealZoneDatabase;

class ForwardCommitFailure extends RealZoneDatabase {
  ForwardCommitFailure(LocalDatabase database) : super(database, Zone.current);
  bool fail = true;
  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction) mutate, {
    StoreToken? expected,
  }) async {
    final result = await database.apply(action, mutate, expected: expected);
    if (fail) {
      throw StateError('Synthetic forwarding error AFTER real COMMIT');
    }
    return result;
  }
}

class MissingDependencyFinish extends WorkoutRepository {
  MissingDependencyFinish(super.db) : super.local();
  bool completedSql = false;
  @override
  PreparedDomainAction prepareFinish({
    required SessionWrite write,
    required int baseRevision,
    required Map<String, int> setBases,
    required Map<String, Object?> recovery,
    required int draftRevision,
    required String draftId,
    String? operationId,
    List<OperationDependency> dependencies = const [],
  }) => super.prepareFinish(
    write: write,
    baseRevision: baseRevision,
    setBases: setBases,
    recovery: recovery,
    draftRevision: draftRevision,
    draftId: draftId,
    operationId: operationId,
    dependencies: [
      ...dependencies,
      OperationDependency(
        db.profileId,
        GrantFamily.workouts,
        'missing-workflow-dependency',
      ),
    ],
  );
  @override
  Future<Object?> executePreparedInTransaction(
    LocalTransaction tx,
    PreparedDomainAction intent,
  ) async {
    final result = await super.executePreparedInTransaction(tx, intent);
    completedSql = true;
    return result;
  }
}

/// Gates only scheduling, while each callback/COMMIT executes on real SQLite.
class PendingDraftGate extends RealZoneDatabase {
  PendingDraftGate(LocalStore store, {required this.afterCommit})
    : super(store, Zone.current);
  final bool afterCommit;
  bool failNext = true, gateWrites = false;
  final entered = Completer<void>(), release = Completer<void>();
  final trace = <String>[];
  int writes = 0;
  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) async {
    final index = ++writes;
    trace.add('write-$index-enter');
    if (gateWrites && !release.isCompleted) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    final fault = failNext;
    failNext = false;
    try {
      final result = await super.writeTransaction((tx) async {
        final result = await callback(tx);
        trace.add('write-$index-sql-complete');
        if (fault && !afterCommit) {
          await tx
              .execute('INSERT INTO operation_dependencies VALUES(?,?,?,?)', [
                profileId,
                GrantFamily.workouts.name,
                'synthetic-draft-request',
                'missing-synthetic-parent',
              ]);
        }
        return result;
      }, expected: expected);
      trace.add('write-$index-real-commit');
      if (fault && afterCommit) {
        throw StateError('Synthetic draft forwarding error AFTER real COMMIT');
      }
      return result;
    } catch (e) {
      trace.add('write-$index-error:$e');
      rethrow;
    }
  }
}

Future<Object?> persistenceOutcome(Future<void> future) async {
  try {
    await future.timeout(const Duration(seconds: 8));
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'controller retains original finish across forwarding failure after actual COMMIT; stale autosave cannot recreate draft',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-controller-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      final store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: workflowSchemaRegistry(),
      );
      ActiveSessionController? controller;
      try {
        await ExerciseRepository.local(store).commitPrepared(
          prepareDomain(
            store,
            RecordKind.exercise,
            LocalActionKind.definitionCreate,
            'exercise',
            0,
            {
              'fields': {
                'name': 'Synthetic',
                'plate_step_kg': '2.50',
                'is_template': 0,
              },
            },
          ),
        );
        final d = DraftStore.local(store);
        await d.load();
        final exercise = Exercise(
          id: 'exercise',
          name: 'Synthetic',
          slug: 'synthetic',
          muscleGroup: 'legs',
          compound: false,
          plateStepKg: 2.5,
          isTemplate: false,
        );
        final draft = SessionDraft(
          templateId: null,
          name: 'Synthetic',
          focus: 'legs',
          startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
          blocks: [
            BlockState(
              exercise: exercise,
              resolved: ResolvedSlot(
                exercise: exercise,
                workSets: 2,
                warmupSets: 0,
                repLow: 5,
                repHigh: 8,
                rirLow: 1,
                rirHigh: 2,
              ),
              warmupSets: [],
              workingSets: [
                SetState(
                  id: 'done',
                  weightKg: 80.125,
                  reps: 5,
                  rir: 9,
                  isWarmup: false,
                  done: true,
                  originalWeight: '80.125000000000000100',
                ),
                SetState(
                  id: 'planned',
                  weightKg: 81.5,
                  reps: 5,
                  rir: null,
                  isWarmup: false,
                  done: false,
                ),
              ],
              expanded: true,
            ),
          ],
        );
        controller = ActiveSessionController.fromDraft(draft, draftStore: d);
        controller.setRestRaw(DateTime.now(), 120);
        await controller.flushPersistence();
        final stale = PreparedWorkflowState(
          store,
          controller.snapshot().toJson(),
          controller.snapshot().timerJson,
          d.persistedRevision,
        );
        final database = ForwardCommitFailure(store),
            repo = WorkoutRepository.local(database);
        final intent = controller.prepareFinish(repo);
        final bytes = base64Encode(intent.action.bytes),
            id = intent.action.target.id;
        await expectLater(controller.commitFinish(repo), throwsStateError);
        expect(controller.hasSession, isTrue);
        expect(controller.lastFinished, isNull);
        expect(identical(controller.pendingFinish, intent), isTrue);
        expect(
          store.pendingRecoveryAction,
          isNull,
          reason: 'controller owes intent independently of store recovery',
        );
        expect((await store.getAll('SELECT * FROM sessions')).single['id'], id);
        expect(
          (await store.get(
            'SELECT * FROM local_state WHERE state_kind=\'draft\'',
          ))['status'],
          'completed',
        );
        expect(
          () => controller!.addRestTime(30),
          throwsA(isA<StoreException>()),
        );
        controller.draft.blocks.single.workingSets.first.weightKg = 999;
        await checkpoint(store, root, 'real-commit-forwarded-error');
        database.fail = false;
        expect(await controller.commitFinish(repo), id);
        expect(base64Encode(intent.action.bytes), bytes);
        expect(controller.hasSession, isFalse);
        expect(
          (await store.get('SELECT * FROM sets'))['weight_kg'],
          '80.125000000000000100',
        );
        expect((await store.getAll('SELECT * FROM sessions')).length, 1);
        await expectLater(
          commitWorkflowState(store, stale),
          throwsA(isA<StoreException>()),
        );
        expect(
          (await store.get(
            'SELECT * FROM local_state WHERE state_kind=\'draft\'',
          ))['status'],
          'completed',
        );
        await checkpoint(store, root, 'replayed-stale-refused');
        controller.dispose();
        controller = null;
        final expected = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          final reopened = await LocalStore.open(
            profile: profile,
            expectedProfileId: profile.profileId,
            schema: workflowSchemaRegistry(),
          );
          expect(await reopened.inventory(), expected);
          await checkpoint(reopened, root, 'reopen-$i');
          await reopened.close();
        }
      } finally {
        controller?.dispose();
        await store.close();
        await archiveOwned(root);
      }
    },
  );
  test(
    'closed recovery after actual failed workflow COMMIT retains original controller intent and prior good recovery until exact retry',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-closed-recovery-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      final store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: workflowSchemaRegistry(),
      );
      ActiveSessionController? controller;
      StreamSubscription<RecoveryPhase>? subscription;
      try {
        await ExerciseRepository.local(store).commitPrepared(
          prepareDomain(
            store,
            RecordKind.exercise,
            LocalActionKind.definitionCreate,
            'workflow-ex',
            0,
            {
              'fields': {'name': 'Synthetic', 'is_template': 0},
            },
          ),
        );
        final draft = SessionDraft.fromJson(
              Map<String, dynamic>.from(workflowDraft()),
            ),
            d = DraftStore.local(store);
        await d.save(draft);
        final previous = FinishedSession(
          sessionId: 'prior-good',
          sessionDate: '2026-10-14',
          finishedAt: DateTime.now(),
          elapsedSeconds: 60,
          draft: draft.deepCopy(),
        );
        await FinishedSessionStore.local(store).save(previous);
        controller = ActiveSessionController.fromDraft(draft, draftStore: d);
        final before = await store.inventory();
        await checkpoint(store, root, 'prior-good');
        final repository = MissingDependencyFinish(store),
            intent = controller.prepareFinish(repository),
            frozen = base64Encode(controller.pendingFinish!.action.bytes);
        final good = File('${root.path}/pool-closed-preserved.sqlite');
        var corrupted = false;
        final phases = <String>[];
        subscription = store.recoveryEvents.listen((phase) {
          phases.add(phase.name);
          if (phase == RecoveryPhase.poolClosed && !corrupted) {
            File(store.path).copySync(good.path);
            File(store.path).writeAsBytesSync([0, 255, 1, 2], flush: true);
            corrupted = true;
          }
        });
        await expectLater(
          controller.commitFinish(repository),
          throwsA(anything),
        );
        expect(repository.completedSql, isTrue);
        expect(corrupted, isTrue);
        expect(store.admission, StoreAdmission.closed);
        expect(store.pendingRecoveryAction!.hash, intent.action.hash);
        expect(identical(controller.pendingFinish, intent), isTrue);
        expect(controller.hasSession, isTrue);
        expect(controller.lastFinished, isNull);
        await expectLater(
          store.inventory(),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'closed admission',
              'recovery_required',
            ),
          ),
        );
        await File(
          store.path,
        ).copy('${root.path}/failed-recovery-corrupt.sqlite');
        await subscription.cancel();
        subscription = null;
        await File('${root.path}/recovery-phases.json').writeAsString(
          jsonEncode({
            'phases': phases,
            'callback_sql_completed': repository.completedSql,
            'operation_id': intent.action.operationId,
            'hash': intent.action.hash,
            'input_bytes_base64': frozen,
            'base': intent.action.baseLocalRevision,
            'profile': intent.token.profileId,
            'generation': intent.token.generation,
          }),
          flush: true,
        );
        await good.copy(store.path);
        await store.recover();
        expect(await store.inventory(), before);
        expect(
          (await FinishedSessionStore.local(store).load())!.sessionId,
          'prior-good',
        );
        expect(controller.pendingFinish!.action.hash, intent.action.hash);
        expect(base64Encode(controller.pendingFinish!.action.bytes), frozen);
        await ExerciseRepository.local(store).commitPrepared(
          prepareDomain(
            store,
            RecordKind.exercise,
            LocalActionKind.definitionCreate,
            'dependency-exercise',
            0,
            {
              'fields': {'name': 'Dependency', 'is_template': 0},
            },
            operationId: 'missing-workflow-dependency',
          ),
        );
        await controller.commitFinish(repository);
        expect(controller.hasSession, isFalse);
        expect((await store.getAll('SELECT * FROM sessions')).length, 1);
        controller.dispose();
        controller = null;
        await checkpoint(store, root, 'recovered-exact-retry');
        final expected = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          final reopened = await LocalStore.open(
            profile: profile,
            expectedProfileId: profile.profileId,
            schema: workflowSchemaRegistry(),
          );
          expect(await reopened.inventory(), expected);
          await checkpoint(reopened, root, 'reopen-$i');
          await reopened.close();
        }
      } finally {
        await subscription?.cancel();
        controller?.dispose();
        await store.close();
        await archiveOwned(root);
      }
    },
  );
  for (final after in [false, true]) {
    test(
      'E1 real pending draft ${after ? 'forwarded COMMIT' : 'COMMIT refusal'} competing manager/controller flushes cannot strand exact prepared Finish',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'alkion-workflow-flush-finish-',
        );
        final profile = await AlkionProfile.open(
          supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
        );
        final store = await LocalStore.open(
          profile: profile,
          expectedProfileId: profile.profileId,
          schema: workflowSchemaRegistry(),
        );
        final gate = PendingDraftGate(store, afterCommit: after);
        ActiveSessionController? controller;
        SessionManager? manager;
        try {
          await seed(store, RecordKind.exercise, 'workflow-ex', {
            'name': 'Synthetic workflow',
            'is_template': 0,
          });
          final draft = SessionDraft.fromJson(
            Map<String, dynamic>.from(workflowDraft()),
          );
          final drafts = DraftStore.local(gate);
          await drafts.load();
          await expectLater(drafts.save(draft), throwsA(anything));
          final pending = drafts.pending!;
          final pendingBytes = base64Encode(pending.bytes);
          expect(drafts.persistedRevision, 0);
          await checkpoint(store, root, 'uncertain-draft');
          gate.gateWrites = true;
          controller = ActiveSessionController.fromDraft(
            draft,
            draftStore: drafts,
          );
          manager = SessionManager(
            draftStore: drafts,
            finishedStore: FinishedSessionStore.local(store),
          );
          manager.register(controller);
          await gate.entered.future.timeout(const Duration(seconds: 8));
          final managerFlush = persistenceOutcome(manager.flushPersistence());
          final controllerFlush = persistenceOutcome(
            controller.flushPersistence(),
          );
          final repository = WorkoutRepository.local(store);
          final intent = controller.prepareFinish(
            repository,
            at: DateTime.utc(2026, 10, 13, 12, 8),
          );
          final originalBytes = base64Encode(intent.action.bytes);
          final originalId = intent.action.operationId;
          final originalHash = intent.action.hash;
          final observations = <String, Object?>{
            'after_real_commit': after,
            'operation_id': originalId,
            'hash': originalHash,
            'bytes': intent.action.bytes,
            'base': intent.action.baseLocalRevision,
            'target': intent.action.target.id,
            'token_profile': intent.token.profileId,
            'token_generation': intent.token.generation,
            'pending_expected_revision': pending.expectedRevision,
            'pending_bytes': pending.bytes,
            'pending_timer_bytes': pending.timerBytes,
          };
          expect(base64Encode(drafts.pending!.bytes), pendingBytes);
          gate.trace.add('finish-prepared-before-release');
          gate.release.complete();
          final flushErrors = await Future.wait([
            managerFlush,
            controllerFlush,
          ]);
          observations['competing_flush_errors'] = [
            for (final e in flushErrors) e?.toString(),
          ];
          observations['manager_error'] = manager.persistenceError?.toString();
          observations['draft_before_finish'] = await store.getAll(
            "SELECT * FROM local_state WHERE state_kind='draft'",
          );
          Object? finishError, retryError;
          String? finishedId;
          try {
            finishedId = await controller
                .commitFinish(repository)
                .timeout(const Duration(seconds: 8));
          } catch (e) {
            finishError = e;
          }
          if (finishError != null) {
            try {
              finishedId = await controller
                  .commitFinish(repository)
                  .timeout(const Duration(seconds: 8));
            } catch (e) {
              retryError = e;
            }
          }
          observations['finish_error'] = finishError?.toString();
          observations['retry_error'] = retryError?.toString();
          observations['finished_id'] = finishedId;
          observations['trace'] = gate.trace;
          await File(
            '${root.path}/interleaving.json',
          ).writeAsString(jsonEncode(observations), flush: true);
          await checkpoint(store, root, 'finish-outcome');
          expect(intent.action.operationId, originalId);
          expect(intent.action.hash, originalHash);
          expect(base64Encode(intent.action.bytes), originalBytes);
          manager.dispose();
          manager = null;
          controller.dispose();
          controller = null;
          final expected = await store.inventory();
          await store.close();
          for (var i = 0; i < 2; i++) {
            final reopened = await LocalStore.open(
              profile: profile,
              expectedProfileId: profile.profileId,
              schema: workflowSchemaRegistry(),
            );
            expect(await reopened.inventory(), expected);
            await checkpoint(reopened, root, 'reopen-$i');
            await reopened.close();
          }
          expect(
            finishError,
            isNull,
            reason:
                'normal overlapping flushes must not stale the immutable Finish base; trace archived',
          );
          expect(retryError, isNull);
          expect(finishedId, intent.action.target.id);
          expect(
            flushErrors
                .where((e) => e != null)
                .every(
                  (e) =>
                      e is StoreException &&
                      e.category == 'finish_retry_required',
                ),
            isTrue,
          );
          expect(
            (expected['sessions'] as List).single['id'],
            intent.action.target.id,
          );
          expect((expected['sessions'] as List).single['date'], '2026-10-13');
          expect((expected['sets'] as List).map((s) => s['id']).toSet(), {
            'workflow-warmup',
            'workflow-set',
          });
          expect(
            (expected['sets'] as List).singleWhere(
              (s) => s['id'] == 'workflow-set',
            )['weight_kg'],
            '80.12500000000000000100',
          );
          expect((expected['operations'] as List), hasLength(1));
          expect(
            (expected['operations'] as List).single['operation_id'],
            originalId,
          );
          expect(
            (expected['local_state'] as List)
                .where(
                  (s) =>
                      s['state_kind'] == 'draft' || s['state_kind'] == 'timer',
                )
                .every((s) => s['status'] == 'completed'),
            isTrue,
          );
        } finally {
          if (!gate.release.isCompleted) gate.release.complete();
          manager?.dispose();
          controller?.dispose();
          await store.close();
          await archiveOwned(root);
        }
      },
    );
  }
}
