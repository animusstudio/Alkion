import 'dart:convert';

import '../data/exercise_repository.dart'
    show domainUuid, observedRecord, projectionFields, putDomain;
import '../data/models.dart' show hasQualifiedCalendarDay;
import '../domain/evidence.dart';
import '../domain/local_action.dart';
import '../store/local_store.dart';

/// Selected-ID actions for retained measurements whose raw date is missing,
/// null, empty or not a qualified calendar day. The retained measurement
/// repository strictly requires a calendar day; this seam never invents one.
/// Each action names the observed record ID and revision, commits its own
/// outbox entry and leaves the raw date projection byte-identical.
final class HistoricalMeasurementActions {
  HistoricalMeasurementActions(this.db);
  final LocalDatabase db;

  /// Measurements with an unavailable date, including tombstones so they can
  /// be restored by selected ID.
  Future<List<Map<String, dynamic>>> unavailableDateEntries() async => [
    for (final row in await db.getAll(
      'SELECT * FROM bodyweight_logs WHERE profile_id=? ORDER BY id',
      [db.profileId],
    ))
      if (!hasQualifiedCalendarDay(
        row['date'] is String ? row['date'] as String : null,
      ))
        row,
  ];

  LocalAction prepare({
    required String selectedId,
    required int observedRevision,
    required LocalActionKind action,
    ExactDecimal? weightKg,
    String? operationId,
  }) {
    if (!const {
      LocalActionKind.bodyweightEdit,
      LocalActionKind.bodyweightDelete,
      LocalActionKind.bodyweightRestore,
    }.contains(action)) {
      throw const StoreException('unsupported_action');
    }
    if ((action == LocalActionKind.bodyweightEdit) != (weightKg != null)) {
      throw const StoreException('malformed_value');
    }
    return LocalAction(
      operationId: operationId ?? domainUuid.v4(),
      target: LocalRef(db.profileId, RecordKind.bodyweight, selectedId),
      action: action,
      baseLocalRevision: observedRevision,
      createdAt: OperationInstant.now(),
      input: {
        'selected_id': selectedId,
        'observed_revision': observedRevision,
        'weight_kg': weightKg?.text,
        'raw_date': 'untouched',
      },
    );
  }

  Future<LocalActionResult> commit(LocalAction action) => db.apply(action, (
    tx,
  ) async {
    final ref = action.target;
    final input = <String, Object?>{
      'weight_kg': action.action == LocalActionKind.bodyweightEdit
          ? _weight(action)
          : null,
    };
    final old = await observedRecord(
      tx,
      ref,
      action.baseLocalRevision,
      allowDeleted: action.action == LocalActionKind.bodyweightRestore,
    );
    final date = old['date'];
    if (hasQualifiedCalendarDay(date is String ? date : null)) {
      throw const StoreException('qualified_date_uses_measurement_repository');
    }
    if (action.action == LocalActionKind.bodyweightRestore &&
        old['deleted'] != 1) {
      throw const StoreException('not_deleted');
    }
    final fields = projectionFields(old);
    if (action.action == LocalActionKind.bodyweightEdit) {
      fields['weight_kg'] = input['weight_kg'];
    }
    final revision = await putDomain(
      tx,
      ref,
      fields,
      deleted: action.action == LocalActionKind.bodyweightDelete,
      sourceRevisionId: old['source_revision_id'] as String?,
    );
    return {'id': ref.id, 'revision': revision};
  });

  String _weight(LocalAction action) {
    final text = (decodeAction(action)['input'] as Map)['weight_kg'];
    if (text is! String || ExactDecimal.tryParse(text) == null) {
      throw const StoreException('malformed_value');
    }
    return text;
  }
}

/// Own canonical local action bytes; the weight is a decimal string.
Map<String, dynamic> decodeAction(LocalAction action) =>
    Map<String, dynamic>.from(jsonDecode(utf8.decode(action.bytes)) as Map);
