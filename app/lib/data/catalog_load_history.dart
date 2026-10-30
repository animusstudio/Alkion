import '../domain/catalog_execution.dart';
import '../domain/evidence.dart';
import '../store/local_store.dart';
import 'models.dart' show hasQualifiedCalendarDay;

/// Works on pre-catalog schemas too: immutable revision JSON declares typed
/// evidence, so legacy reads never need a column absent from an old snapshot.
const legacySetOnlySql =
    "NOT EXISTS (SELECT 1 FROM record_revisions catalog_revision WHERE catalog_revision.profile_id=s.profile_id AND catalog_revision.kind='workoutSet' AND catalog_revision.record_id=s.id AND catalog_revision.revision=s.revision AND json_type(CAST(catalog_revision.payload_bytes AS TEXT),'\$.catalog_set_bytes')='array')";

final class CatalogLoadReference {
  const CatalogLoadReference({
    this.last,
    this.bestKg,
    this.lastMetrics,
    this.bestMetrics,
  });
  final ({double weightKg, int reps, String date})? last;
  final double? bestKg;
  final Map<String, CatalogMetricEvidence>? lastMetrics, bestMetrics;
}

final class CatalogLoadObservation {
  CatalogLoadObservation(this.row, this.evidence, this.load, this.reps);
  final Map<String, dynamic> row;
  final CatalogSetEvidence evidence;
  final ExactDecimal load;
  final int reps;
}

List<CatalogLoadObservation> catalogLoadObservations(
  List<Map<String, dynamic>> rows,
  CatalogSelectionEvidence selection,
) {
  if (!selection.supportsLoadProgression) return [];
  final values = <CatalogLoadObservation>[];
  for (final row in rows) {
    if (row['catalog_set_bytes'] == null || row['is_warmup'] != 0) continue;
    final evidence = CatalogSetEvidence.fromJson(
      decodeCatalogBytes(row['catalog_set_bytes']!),
    );
    if (evidence.selection.compatibilityKey != selection.compatibilityKey) {
      continue;
    }
    final load = evidence.metrics['reported_load']?.loadKg;
    final repetition = evidence.metrics['repetitions'];
    final reps = repetition?.state == ValueState.valid
        ? int.tryParse(repetition!.raw as String)
        : null;
    if (load != null && reps != null && reps > 0) {
      values.add(CatalogLoadObservation(row, evidence, load, reps));
    }
  }
  return values;
}

int compareCatalogLoad(CatalogLoadObservation a, CatalogLoadObservation b) {
  final weight = a.load.compareTo(b.load);
  if (weight != 0) return weight;
  final reps = a.reps.compareTo(b.reps);
  if (reps != 0) return reps;
  final order = (b.row['set_number'] as int).compareTo(
    a.row['set_number'] as int,
  );
  return order != 0
      ? order
      : (b.row['id'] as String).compareTo(a.row['id'] as String);
}

Future<CatalogLoadReference> readCatalogLoadReference(
  LocalRead tx,
  CatalogSelectionEvidence selection, {
  String? excludeSessionId,
}) async {
  if (!selection.supportsLoadProgression) return const CatalogLoadReference();
  final rows = await tx.getAll(
    'SELECT s.*,se.date,se.created_at AS session_created_at FROM sets s JOIN sessions se ON se.profile_id=s.profile_id AND se.id=s.session_id WHERE s.profile_id=? AND s.tracking_context_id=? AND s.deleted=0 AND se.deleted=0 ${excludeSessionId == null ? '' : 'AND s.session_id!=?'} ORDER BY se.date DESC,se.created_at DESC,se.id DESC,s.set_number,s.id',
    [
      tx.profileId,
      selection.contextId,
      if (excludeSessionId != null) excludeSessionId,
    ],
  );
  final values = catalogLoadObservations(
    rows
        .where(
          (row) => hasQualifiedCalendarDay(
            row['date'] is String ? row['date'] as String : null,
          ),
        )
        .toList(),
    selection,
  );
  if (values.isEmpty) return const CatalogLoadReference();
  final best = values.reduce((a, b) => compareCatalogLoad(a, b) >= 0 ? a : b);
  final lastSession = values.first.row['session_id'];
  final last = values
      .where((v) => v.row['session_id'] == lastSession)
      .reduce((a, b) => compareCatalogLoad(a, b) >= 0 ? a : b);
  final display = last.load.displayDouble;
  return CatalogLoadReference(
    last: display == null || !display.isFinite
        ? null
        : (
            weightKg: display,
            reps: last.reps,
            date: last.row['date']?.toString() ?? '',
          ),
    bestKg: best.load.displayDouble?.isFinite == true
        ? best.load.displayDouble
        : null,
    lastMetrics: last.evidence.metrics,
    bestMetrics: best.evidence.metrics,
  );
}

Future<void> writeCatalogDerivations(
  LocalTransaction tx,
  String sessionId,
  int workoutRevision,
) async {
  final rows = await tx.getAll(
    'SELECT * FROM sets WHERE profile_id=? AND session_id=? AND deleted=0 ORDER BY set_number,id',
    [tx.profileId, sessionId],
  );
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final row in rows) {
    if (row['catalog_set_bytes'] == null) continue;
    final evidence = CatalogSetEvidence.fromJson(
      decodeCatalogBytes(row['catalog_set_bytes']!),
    );
    (groups[evidence.selection.compatibilityKey] ??= []).add(row);
  }
  for (final group in groups.values) {
    final selection = CatalogSetEvidence.fromJson(
      decodeCatalogBytes(group.first['catalog_set_bytes']!),
    ).selection;
    final supported = catalogLoadObservations(group, selection);
    final top = supported.isEmpty
        ? null
        : supported.reduce((a, b) => compareCatalogLoad(a, b) >= 0 ? a : b);
    final reference = await readCatalogLoadReference(
      tx,
      selection,
      excludeSessionId: sessionId,
    );
    final previous = reference.bestMetrics?['reported_load']?.loadKg;
    final pr =
        top != null && previous != null && top.load.compareTo(previous) > 0;
    for (final row in group) {
      await tx.execute('INSERT INTO derived_results VALUES(?,?,?,?,?,?,?,?)', [
        tx.profileId,
        'catalog-workout:$sessionId:$workoutRevision:set:${row['id']}:${row['revision']}',
        'catalog-load/1',
        'exact-context',
        localBytes({
          'workout': sessionId,
          'workoutRevision': workoutRevision,
          'set': row['id'],
          'revision': row['revision'],
        }),
        localBytes({
          'is_top_set': row['id'] == top?.row['id'] ? 1 : 0,
          'is_pr': pr && row['id'] == top.row['id'] ? 1 : 0,
        }),
        localBytes({
          'supported': selection.supportsLoadProgression,
          'compatibilityKey': selection.compatibilityKey,
          'known': supported.length,
          'total': group.length,
          'rule': 'exact-kg-load/reps/order/id',
        }),
        OperationInstant.now().text,
      ]);
    }
  }
}
