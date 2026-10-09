import 'package:powersync/powersync.dart';

import '../capture/source_write_gate.dart';
import 'models.dart';
import 're_listenable.dart';

/// Pure + testable: builds the SQL upsert op for a bodyweight log entry.
///
/// If [existingId] is non-null, returns an UPDATE reusing that id.
/// If null, returns an INSERT using [newId].
/// `weight_kg` is TEXT (`toStringAsFixed(2)`); `user_id`/`created_at` are
/// omitted (server stamps from token / server defaults — like persistSession).
({String sql, List<Object?> args}) bodyweightUpsertOp(
    String? existingId, String dateIso, double kg, String newId) {
  final w = kg.toStringAsFixed(2);
  return existingId != null
      ? (
          sql: 'UPDATE bodyweight_logs SET weight_kg = ? WHERE id = ?',
          args: [w, existingId]
        )
      : (
          sql: 'INSERT INTO bodyweight_logs (id, date, weight_kg) VALUES (?, ?, ?)',
          args: [newId, dateIso, w]
        );
}

/// Repository for bodyweight_logs.
class BodyweightRepository {
  final PowerSyncDatabase db;

  const BodyweightRepository(this.db);

  /// A live stream of all bodyweight entries ordered oldest-first.
  ///
  /// `weight_kg` is stored as TEXT on the client; the CAST produces a real
  /// value aliased as `weight` so [BodyweightEntry.fromRow] can read it.
  Stream<List<BodyweightEntry>> watchSeriesAsc() {
    return reListenable(() => db
        .watch(
          'SELECT date, CAST(weight_kg AS REAL) AS weight '
          'FROM bodyweight_logs ORDER BY date ASC',
        )
        .map((rs) => rs.map(BodyweightEntry.fromRow).toList()));
  }

  /// Logs (or updates) today's bodyweight with a client-side same-day upsert.
  ///
  /// The server has no `UNIQUE(user_id, date)` constraint and `applyBodyweight`
  /// upserts on `ON CONFLICT(id)` only — reusing the existing same-day id turns
  /// a second save into a PATCH-in-place instead of creating a duplicate row.
  Future<void> logBodyweight({
    required String dateIso,
    required double kg,
  }) async {
    await runSourceWrite(
      'bodyweight.log',
      (_) => db.writeTransaction((tx) async {
        final existing = await tx.getOptional(
          'SELECT id FROM bodyweight_logs WHERE date = ? LIMIT 1',
          [dateIso],
        );
        final op = bodyweightUpsertOp(
            existing?['id'] as String?, dateIso, kg, uuid.v4());
        await tx.execute(op.sql, op.args);
      }),
    );
  }
}
