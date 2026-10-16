import '../domain/evidence.dart';
import '../domain/local_action.dart';
import '../store/local_store.dart';
import 'exercise_repository.dart';
import 'models.dart';
import 're_listenable.dart';

/// Pure + testable: builds the SQL upsert op for a bodyweight log entry.
///
/// If [existingId] is non-null, returns an UPDATE reusing that id.
/// If null, returns an INSERT using [newId].
/// `weight_kg` is TEXT (`toStringAsFixed(2)`); `user_id`/`created_at` are
/// omitted (server stamps from token / server defaults — like persistSession).
({String sql, List<Object?> args}) bodyweightUpsertOp(
  String? existingId,
  String dateIso,
  double kg,
  String newId,
) {
  final w = kg.toStringAsFixed(2);
  return existingId != null
      ? (
          sql: 'UPDATE bodyweight_logs SET weight_kg = ? WHERE id = ?',
          args: [w, existingId],
        )
      : (
          sql:
              'INSERT INTO bodyweight_logs (id, date, weight_kg) VALUES (?, ?, ?)',
          args: [newId, dateIso, w],
        );
}

class BodyweightRepository {
  const BodyweightRepository(Object legacy) : _database = null;
  const BodyweightRepository.local(LocalDatabase database)
    : _database = database;
  final LocalDatabase? _database;
  LocalDatabase get db =>
      _database ??
      (throw const StoreException('legacy_repository_unavailable'));
  Stream<List<BodyweightEntry>> watchSeriesAsc() => reListenable(
    () => db
        .watch(
          'SELECT * FROM bodyweight_logs WHERE profile_id=? AND deleted=0 ORDER BY date,id',
          parameters: [db.profileId],
        )
        .map((rs) => rs.map(BodyweightEntry.fromRow).toList()),
  );
  Future<List<BodyweightEntry>> onDate(String date) async {
    CalendarDay(date);
    final rows = await db.getAll(
      'SELECT * FROM bodyweight_logs WHERE profile_id=? AND deleted=0 AND date=? ORDER BY id',
      [db.profileId, date],
    );
    return rows.map(BodyweightEntry.fromRow).toList();
  }

  PreparedDomainAction prepareMeasurement({
    required String dateIso,
    required DecimalEvidence kg,
    BodyweightEntry? selected,
    String? operationId,
    bool delete = false,
    bool restore = false,
    List<OperationDependency> dependencies = const [],
  }) {
    CalendarDay(dateIso);
    if (selected != null &&
        (selected.id == null ||
            selected.localRevision == null ||
            selected.date != dateIso)) {
      throw const StoreException('observed_revision_required');
    }
    if (selected == null && (delete || restore)) {
      throw const StoreException('observed_revision_required');
    }
    if (!delete &&
        !restore &&
        kg.state != ValueState.valid &&
        selected == null) {
      throw const StoreException('malformed_value');
    }
    return prepareDomain(
      db,
      RecordKind.bodyweight,
      delete
          ? LocalActionKind.bodyweightDelete
          : restore
          ? LocalActionKind.bodyweightRestore
          : selected == null
          ? LocalActionKind.bodyweightRecord
          : LocalActionKind.bodyweightEdit,
      selected?.id ?? domainUuid.v4(),
      selected?.localRevision ?? 0,
      {'date': dateIso, 'weight_kg': kg.raw, 'weight_state': kg.state.name},
      operationId: operationId,
      dependencies: dependencies,
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
    tx.requireRef(a.target, kind: RecordKind.bodyweight);
    final input = intent.input;
    final date = input['date'] as String;
    CalendarDay(date);
    final old = a.baseLocalRevision == 0
        ? null
        : await observedRecord(
            tx,
            a.target,
            a.baseLocalRevision,
            allowDeleted: a.action == LocalActionKind.bodyweightRestore,
          );
    if (old != null && old['date'] != date) {
      throw const StoreException('revision_conflict');
    }
    if (old == null) {
      final same = await tx.getAll(
        'SELECT id FROM bodyweight_logs WHERE profile_id=? AND date=? AND deleted=0',
        [tx.profileId, date],
      );
      if (same.isNotEmpty) {
        throw StoreException(
          same.length > 1
              ? 'ambiguous_reference'
              : 'observed_revision_required',
        );
      }
    }
    final fields = old == null ? <String, Object?>{} : projectionFields(old);
    if (a.action == LocalActionKind.bodyweightRecord ||
        a.action == LocalActionKind.bodyweightEdit) {
      if (input['weight_state'] == ValueState.valid.name &&
          ExactDecimal.tryParse(input['weight_kg'] as String) == null) {
        throw const StoreException('malformed_value');
      }
      fields.addAll({'date': date, 'weight_kg': input['weight_kg']});
    } else if (a.action != LocalActionKind.bodyweightDelete &&
        a.action != LocalActionKind.bodyweightRestore) {
      throw const StoreException('unsupported_action');
    }
    if (a.action == LocalActionKind.bodyweightRestore && old?['deleted'] != 1) {
      throw const StoreException('not_deleted');
    }
    final rev = await putDomain(
      tx,
      a.target,
      fields,
      deleted: a.action == LocalActionKind.bodyweightDelete,
      sourceRevisionId: old?['source_revision_id'] as String?,
    );
    return {'id': a.target.id, 'revision': rev};
  }

  Future<void> logBodyweight({
    required String dateIso,
    required double kg,
  }) async => commitPrepared(
    prepareMeasurement(
      dateIso: dateIso,
      kg: DecimalEvidence(ValueState.valid, kg.toString()),
    ),
  );
}
