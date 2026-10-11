import 'package:powersync/powersync.dart' show PowerSyncDatabase, uuid;

import '../capture/source_write_gate.dart';
import 'models.dart';
import 're_listenable.dart';

/// Default weekly set targets by muscle group.
const _defaults = [
  ('quads', 16),
  ('back', 14),
  ('hamstrings', 12),
  ('chest', 12),
  ('shoulders', 12),
  ('biceps', 10),
  ('calves', 9),
  ('triceps', 9),
];

// ── target edit ops ──────────────────────────────────────────────────────────

({String sql, List<Object?> args}) insertTargetOp(
        String id, String userId, String muscle, int sets, String nowIso) =>
    (
      sql: 'INSERT INTO muscle_targets (id, user_id, muscle, target_sets, created_at) '
          'VALUES (?, ?, ?, ?, ?)',
      args: [id, userId, muscle, sets, nowIso],
    );

({String sql, List<Object?> args}) updateTargetOp(String id, int sets) =>
    (sql: 'UPDATE muscle_targets SET target_sets = ? WHERE id = ?', args: [sets, id]);

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
    return sets > 0 ? insertTargetOp(newId, userId, muscle, sets, nowIso) : null;
  }
  return sets > 0 ? updateTargetOp(existing.id, sets) : deleteTargetOp(existing.id);
}

/// Repository for muscle_targets — targets per muscle group for the weekly
/// volume bars.
class MuscleTargetRepository {
  final PowerSyncDatabase db;

  const MuscleTargetRepository(this.db);

  /// A live stream of all muscle targets ordered alphabetically by muscle.
  Stream<List<MuscleTarget>> watchTargets() {
    return reListenable(() => db
        .watch(
          'SELECT id, muscle, target_sets FROM muscle_targets ORDER BY muscle',
        )
        .map((rs) => rs.map(MuscleTarget.fromRow).toList()));
  }

  /// Inserts the 8 default muscle targets for [userId] if the table is empty.
  ///
  /// The `muscle_targets` table has UNIQUE(user_id, muscle); inserting only
  /// when count=0 prevents duplicates on re-open without needing INSERT OR IGNORE.
  /// If no sessions exist yet (userId is null), seeding is skipped; the
  /// dashboard handles empty targets gracefully.
  ///
  /// One source operation, the count check included; [parent] when it is
  /// part of a larger one (onboarding).
  Future<void> seedDefaultsIfEmpty(String userId, {SourceTicket? parent}) =>
      runSourceWrite('targets.seed', (_) async {
        final count = (await db.get(
                'SELECT COUNT(*) AS n FROM muscle_targets'))['n'] as int? ??
            0;
        if (count > 0) return;

        final nowIso = DateTime.now().toUtc().toIso8601String();
        await db.writeTransaction((tx) async {
          for (final (muscle, targetSets) in _defaults) {
            await tx.execute(
              'INSERT INTO muscle_targets (id, user_id, muscle, target_sets, created_at) '
              'VALUES (?, ?, ?, ?, ?)',
              [uuid.v4(), userId, muscle, targetSets, nowIso],
            );
          }
        });
      }, parent: parent);

  /// Live-persists [muscle]'s weekly target to [sets]. 0 = no goal (deletes).
  Future<void> setTarget({
    required String muscle,
    required int sets,
    required String userId,
    required MuscleTarget? existing,
  }) async {
    final op = targetOpFor(
      existing: existing,
      sets: sets,
      newId: uuid.v4(),
      userId: userId,
      muscle: muscle,
      nowIso: DateTime.now().toUtc().toIso8601String(),
    );
    if (op == null) return;
    await runSourceWrite('targets.set',
        (_) => db.writeTransaction((tx) => tx.execute(op.sql, op.args)));
  }
}
