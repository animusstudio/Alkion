import '../store/local_store.dart';

import 'models.dart';
import '../domain/evidence.dart';
import '../domain/catalog_execution.dart';
import 'catalog_load_history.dart';
import 're_listenable.dart';

/// Repository for per-exercise progress series — one [ProgressPoint] per
/// session, aggregated from the top set and all working sets.
class ProgressRepository {
  final LocalDatabase db;

  const ProgressRepository.local(this.db);

  Stream<List<ProgressPoint>> watchCatalogSeriesFor(
    CatalogSelectionEvidence selection,
  ) => reListenable(
    () => db
        .watch(
          'SELECT s.*,se.date,se.created_at AS session_created_at FROM sets s JOIN sessions se ON se.id=s.session_id AND se.profile_id=s.profile_id WHERE s.profile_id=? AND s.tracking_context_id=? AND s.deleted=0 AND se.deleted=0 ORDER BY se.date,se.created_at,se.id,s.set_number,s.id',
          parameters: [db.profileId, selection.contextId],
        )
        .map((rows) {
          if (!selection.supportsLoadProgression) return <ProgressPoint>[];
          final groups = <String, List<Map<String, dynamic>>>{};
          for (final row in rows) {
            if (!hasQualifiedCalendarDay(
              row['date'] is String ? row['date'] as String : null,
            )) {
              continue;
            }
            (groups[row['session_id'] as String] ??= []).add(row);
          }
          final points = <ProgressPoint>[];
          ExactDecimal? previousBest;
          for (final rows in groups.values) {
            final values = catalogLoadObservations(rows, selection);
            if (values.isEmpty) continue;
            final top = values.reduce(
              (a, b) => compareCatalogLoad(a, b) >= 0 ? a : b,
            );
            final display = top.load.displayDouble;
            final known = values
                .where((value) => value.load.displayDouble?.isFinite == true)
                .toList();
            final volume = known.fold<double>(
              0,
              (sum, value) => sum + value.load.displayDouble! * value.reps,
            );
            final isPr =
                previousBest != null && top.load.compareTo(previousBest) > 0;
            if (previousBest == null || top.load.compareTo(previousBest) > 0) {
              previousBest = top.load;
            }
            points.add(
              ProgressPoint(
                date: top.row['date']?.toString() ?? '',
                dateEvidence: FieldEvidence.fromRow(top.row, 'date'),
                topWeightKg: display?.isFinite == true ? display! : 0,
                topReps: top.reps,
                isPr: isPr,
                volumeKg: volume,
                topAvailable: display?.isFinite == true,
                coverage: CompatibilityCoverage(
                  total: rows.where((row) => row['is_warmup'] == 0).length,
                  known: known.length,
                  knownSubtotal: volume,
                ),
              ),
            );
          }
          return points;
        }),
  );

  /// A live stream of per-session [ProgressPoint]s for [exerciseId], ordered
  /// oldest-first.
  ///
  /// `top_weight` / `top_reps` / `is_pr` are scoped to the row flagged
  /// `is_top_set=1`; `volume` sums weight×reps across ALL working sets.
  /// Values are kept in kg; the view layer converts to display units.
  Stream<List<ProgressPoint>> watchSeriesFor(String exerciseId) => reListenable(
    () => db
        .watch(
          "SELECT s.*, CAST(s.weight_kg AS REAL) AS legacy_weight, CAST(s.weight_kg AS REAL)*s.reps AS legacy_volume, se.date, se.created_at FROM reps_compat1_legacy_local s JOIN sessions se ON se.id=s.session_id AND se.profile_id=s.profile_id WHERE s.deleted=0 AND se.deleted=0 AND s.exercise_id=? AND s.is_warmup=0 ORDER BY se.date ASC,se.created_at ASC,se.id ASC,s.set_number ASC,s.id ASC",
          parameters: [exerciseId],
        )
        .map((rows) {
          final groups = <String, List<Map<String, dynamic>>>{};
          for (final row in rows.where(
            (row) => row['catalog_set_bytes'] == null,
          )) {
            (groups[row['session_id'] as String] ??= []).add(row);
          }
          return groups.values.map((rows) {
            final sets = rows.map(LoggedSet.fromRow).toList();
            final tops = sets.where((s) => s.isTopSet).toList();
            final coverage = CompatibilityCoverage.sets(sets);
            // MAX top weight/reps and the sum reproduce the retained SQL rules.
            final topWeight = rows
                .where((r) => r['legacy_local_top'] == 1)
                .fold<double>(0, (a, r) {
                  final value = (r['legacy_weight'] as num?)?.toDouble() ?? 0;
                  return value > a ? value : a;
                });
            final topReps = tops.fold<int>(
              0,
              (a, b) => b.reps > a ? b.reps : a,
            );
            final available =
                tops.isNotEmpty &&
                tops.every(
                  (s) =>
                      s.weightEvidence?.state.name == 'valid' &&
                      s.repsEvidence?.raw is int,
                );
            return ProgressPoint(
              date: rows.first['date']?.toString() ?? '',
              dateEvidence: FieldEvidence.fromRow(rows.first, 'date'),
              topWeightKg: topWeight,
              topReps: topReps,
              isPr: tops.any((s) => s.isPr),
              volumeKg: rows.fold<double>(
                0,
                (n, r) => n + ((r['legacy_volume'] as num?)?.toDouble() ?? 0),
              ),
              coverage: coverage,
              topAvailable: available,
            );
          }).toList();
        }),
  );
}
