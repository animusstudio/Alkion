import '../store/local_store.dart';

import 'models.dart';
import '../domain/evidence.dart';
import 're_listenable.dart';

/// Repository for per-exercise progress series — one [ProgressPoint] per
/// session, aggregated from the top set and all working sets.
class ProgressRepository {
  final LocalDatabase db;

  const ProgressRepository.local(this.db);

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
          for (final row in rows) {
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
