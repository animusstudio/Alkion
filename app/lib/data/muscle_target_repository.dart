import 'dart:convert';
import '../domain/evidence.dart';
import '../domain/local_action.dart';
import '../store/local_store.dart';
import 'exercise_repository.dart';
import 'models.dart';
import 're_listenable.dart';

// ── target edit ops ──────────────────────────────────────────────────────────

({String sql, List<Object?> args}) insertTargetOp(
  String id,
  String userId,
  String muscle,
  int sets,
  String nowIso,
) => (
  sql:
      'INSERT INTO muscle_targets (id, user_id, muscle, target_sets, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
  args: [id, userId, muscle, sets, nowIso],
);

({String sql, List<Object?> args}) updateTargetOp(String id, int sets) => (
  sql: 'UPDATE muscle_targets SET target_sets = ? WHERE id = ?',
  args: [sets, id],
);

({String sql, List<Object?> args}) deleteTargetOp(String id) =>
    (sql: 'DELETE FROM muscle_targets WHERE id = ?', args: [id]);

/// Picks the right op for setting [muscle]'s weekly target to [sets]:
/// no row + sets>0 → INSERT; existing + sets>0 → UPDATE; existing + 0 → DELETE
/// ("no goal"); no row + 0 → null (nothing to do).
({String sql, List<Object?> args})? targetOpFor({
  required MuscleTarget? existing,
  required int sets,
  required String newId,
  required String userId,
  required String muscle,
  required String nowIso,
}) {
  if (existing == null) {
    return sets > 0
        ? insertTargetOp(newId, userId, muscle, sets, nowIso)
        : null;
  }
  return sets > 0
      ? updateTargetOp(existing.id, sets)
      : deleteTargetOp(existing.id);
}

enum TargetInitialization { unknown, intentionalEmpty, explicitlyInitialized }

class MuscleTargetRepository {
  const MuscleTargetRepository(Object legacy) : _database = null;
  const MuscleTargetRepository.local(LocalDatabase database)
    : _database = database;
  final LocalDatabase? _database;
  LocalDatabase get db =>
      _database ??
      (throw const StoreException('legacy_repository_unavailable'));
  Stream<List<MuscleTarget>> watchTargets() => reListenable(
    () => db
        .watch(
          'SELECT * FROM muscle_targets WHERE profile_id=? AND deleted=0 ORDER BY muscle,id',
          parameters: [db.profileId],
        )
        .map((rs) => rs.map(MuscleTarget.fromRow).toList()),
  );
  Future<TargetInitialization> initialization() => db.readTransaction((
    tx,
  ) async {
    final state = await tx.localState(
      LocalStateKind.goalInitialization,
      'targets',
    );
    if (state == null) return TargetInitialization.unknown;
    final name =
        (jsonDecode(utf8.decode((state['payload_bytes'] as List).cast<int>()))
            as Map)['state'];
    return TargetInitialization.values.firstWhere((s) => s.name == name);
  });
  Future<void> keepEmpty({required int observedStateRevision}) =>
      db.writeTransaction((tx) async {
        final live = await tx.getAll(
          'SELECT id FROM muscle_targets WHERE profile_id=? AND deleted=0',
          [tx.profileId],
        );
        if (live.isNotEmpty) throw const StoreException('goals_not_empty');
        await tx.putLocalState(
          LocalStateKind.goalInitialization,
          'targets',
          localBytes({'state': 'intentionalEmpty'}),
          expectedRevision: observedStateRevision,
        );
      });
  Future<int> initializationRevision() => db.readTransaction(
    (tx) async =>
        (await tx.localState(
              LocalStateKind.goalInitialization,
              'targets',
            ))?['revision']
            as int? ??
        0,
  );
  PreparedDomainAction prepareTarget({
    required String muscle,
    required int sets,
    MuscleTarget? existing,
    String? operationId,
    List<OperationDependency> dependencies = const [],
  }) {
    if (muscle.trim().isEmpty || sets < 0 || sets > 40) {
      throw const StoreException('malformed_value');
    }
    if (existing != null &&
        (existing.localRevision == null || existing.muscle != muscle)) {
      throw const StoreException('observed_revision_required');
    }
    if (sets == 0 && existing == null) {
      throw const StoreException('observed_revision_required');
    }
    return prepareDomain(
      db,
      RecordKind.muscleTarget,
      sets == 0 ? LocalActionKind.targetDelete : LocalActionKind.targetSet,
      existing?.id ?? domainUuid.v4(),
      existing?.localRevision ?? 0,
      {'muscle': muscle, 'sets': sets},
      operationId: operationId,
      dependencies: dependencies,
    );
  }

  PreparedDomainAction prepareRestore(
    MuscleTarget deleted, {
    required int sets,
  }) {
    if (deleted.localRevision == null || sets <= 0) {
      throw const StoreException('observed_revision_required');
    }
    return prepareDomain(
      db,
      RecordKind.muscleTarget,
      LocalActionKind.targetRestore,
      deleted.id,
      deleted.localRevision!,
      {'muscle': deleted.muscle, 'sets': sets},
    );
  }

  Future<LocalActionResult> commitPrepared(PreparedDomainAction intent) =>
      db.apply(
        intent.action,
        (tx) => executePreparedInTransaction(tx, intent),
        expected: intent.token,
      );
  Future<Object?> executePreparedInTransaction(
    LocalTransaction tx,
    PreparedDomainAction intent,
  ) async {
    final a = intent.action;
    if (tx.action?.hash != a.hash) {
      throw const StoreException('prepared_action_mismatch');
    }
    tx.requireRef(a.target, kind: RecordKind.muscleTarget);
    final input = intent.input;
    final muscle = input['muscle'] as String;
    final sets = input['sets'] as int;
    final old = a.baseLocalRevision == 0
        ? null
        : await observedRecord(
            tx,
            a.target,
            a.baseLocalRevision,
            allowDeleted: a.action == LocalActionKind.targetRestore,
          );
    if (old != null && old['muscle'] != muscle) {
      throw const StoreException('revision_conflict');
    }
    final others = await tx.getAll(
      'SELECT id FROM muscle_targets WHERE profile_id=? AND deleted=0 AND muscle=? AND id<>?',
      [tx.profileId, muscle, a.target.id],
    );
    if (others.isNotEmpty) throw const StoreException('ambiguous_reference');
    final fields = old == null ? <String, Object?>{} : projectionFields(old);
    fields.addAll({'muscle': muscle, 'target_sets': sets});
    final revision = await putDomain(
      tx,
      a.target,
      fields,
      deleted: sets == 0,
      sourceRevisionId: old?['source_revision_id'] as String?,
    );
    final live = await tx.getAll(
      'SELECT id FROM muscle_targets WHERE profile_id=? AND deleted=0',
      [tx.profileId],
    );
    final state = await tx.localState(
      LocalStateKind.goalInitialization,
      'targets',
    );
    await tx.putLocalState(
      LocalStateKind.goalInitialization,
      'targets',
      localBytes({
        'state': live.isEmpty ? 'intentionalEmpty' : 'explicitlyInitialized',
      }),
      expectedRevision: state?['revision'] as int? ?? 0,
    );
    return {'id': a.target.id, 'revision': revision};
  }

  Future<void> setTarget({
    required String muscle,
    required int sets,
    required String userId,
    required MuscleTarget? existing,
  }) async {
    if (existing == null && sets == 0) return;
    await commitPrepared(
      prepareTarget(muscle: muscle, sets: sets, existing: existing),
    );
  }

  Future<void> seedDefaultsIfEmpty(String userId, {Object? parent}) async =>
      throw const StoreException('target_reseeding_unavailable');
}
