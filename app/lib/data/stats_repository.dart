import '../store/local_store.dart';

import '../util/calendar_keys.dart';
import 're_listenable.dart';
import '../domain/evidence.dart';

// Qualification for the pinned SQLite calendar projection. Equality rejects
// SQLite rollover normalization; the original date text stays in its record.
const _qualifiedStatsDay =
    "length(se.date)=10 AND se.date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND se.date>='0001-01-01' AND date(se.date)=se.date";

/// Labeled weekly working sets and the sets whose muscle is unavailable.
/// Unknown evidence is deliberately separate from canonical/custom labels.
final class WeeklyMuscleVolume {
  WeeklyMuscleVolume({
    required List<({String muscle, int sets})> groups,
    required this.unknownSets,
  }) : groups = List.unmodifiable(groups);
  final List<({String muscle, int sets})> groups;
  final int unknownSets;
}

/// Repository for aggregate stats derived from sets + sessions.
///
/// All week-bounded queries accept a [weekStart] (Monday 00:00) and bind
/// its ISO-8601 string via the NAMED `parameters:` argument — consistent
/// with [LocalDatabase.watch]'s API.  The scalar streams map the
/// first row's `n` column; the list streams use the nested `.map` pattern.
class StatsRepository {
  final LocalDatabase db;

  const StatsRepository.local(this.db);

  Stream<({int known, int total})> watchDateCoverage() => reListenable(
    () => db
        .watch(
          'SELECT COUNT(*) AS total,COALESCE(SUM(CASE WHEN $_qualifiedStatsDay THEN 1 ELSE 0 END),0) AS known FROM sessions se WHERE se.deleted=0',
        )
        .map(
          (rows) => (
            known: rows.single['known'] as int,
            total: rows.single['total'] as int,
          ),
        ),
  );

  // ── Scalar week-bounded counts ────────────────────────────────────────────

  /// Live count of working sets logged since [weekStart] (Monday of current week).
  Stream<int> watchSetsThisWeek({required DateTime weekStart}) {
    return reListenable(
      () => db
          .watch(
            'SELECT COUNT(*) AS n '
            'FROM reps_compat1_legacy_local s '
            'JOIN sessions se ON se.id = s.session_id '
            'WHERE s.deleted=0 AND se.deleted=0 AND s.is_warmup = 0 AND $_qualifiedStatsDay AND se.date >= ?',
            parameters: [isoDate(weekStart)],
          )
          .map((rs) => rs.first['n'] as int? ?? 0),
    );
  }

  /// Live count of working sets logged in the week before [weekStart]
  /// (`[weekStart − 7 days, weekStart)`), for Today's week-over-week line.
  Stream<int> watchSetsLastWeek({required DateTime weekStart}) {
    // Date-component subtraction (not `Duration(days: 7)`), matching
    // `weekStart()` in util/dates.dart — a `Duration` subtraction crosses a
    // DST change at the local-time boundary and lands on the previous day
    // 23:00, widening this to an 8-day window.
    final from = isoDate(
      DateTime(weekStart.year, weekStart.month, weekStart.day - 7),
    );
    final to = isoDate(weekStart);
    // SQL: SELECT COUNT(*) AS n FROM reps_compat1_legacy_local s JOIN sessions se ON se.id = s.session_id
    //      WHERE s.deleted=0 AND se.deleted=0 AND s.is_warmup = 0 AND $_qualifiedStatsDay AND se.date >= ? AND se.date < ?
    return reListenable(
      () => db
          .watch(
            'SELECT COUNT(*) AS n '
            'FROM reps_compat1_legacy_local s '
            'JOIN sessions se ON se.id = s.session_id '
            'WHERE s.deleted=0 AND se.deleted=0 AND s.is_warmup = 0 AND $_qualifiedStatsDay AND se.date >= ? AND se.date < ?',
            parameters: [from, to],
          )
          .map((rs) => rs.first['n'] as int? ?? 0),
    );
  }

  /// Live count of distinct muscle groups trained since [weekStart].
  Stream<int> watchDistinctMusclesThisWeek({required DateTime weekStart}) {
    return reListenable(
      () => db
          .watch(
            'SELECT COUNT(DISTINCT ex.muscle_group) AS n '
            'FROM reps_compat1_legacy_local s '
            'JOIN sessions se ON se.id = s.session_id '
            'JOIN exercises ex ON ex.id = s.exercise_id '
            'WHERE s.deleted=0 AND se.deleted=0 AND s.is_warmup = 0 AND $_qualifiedStatsDay AND se.date >= ?',
            parameters: [isoDate(weekStart)],
          )
          .map((rs) => rs.first['n'] as int? ?? 0),
    );
  }

  /// Live count of PR sets logged since [weekStart].
  Stream<int> watchPrsThisWeek({required DateTime weekStart}) {
    return reListenable(
      () => db
          .watch(
            'SELECT COUNT(*) AS n '
            'FROM reps_compat1_legacy_local s '
            'JOIN sessions se ON se.id = s.session_id '
            'WHERE s.deleted=0 AND se.deleted=0 AND s.legacy_local_pr = 1 AND $_qualifiedStatsDay AND se.date >= ?',
            parameters: [isoDate(weekStart)],
          )
          .map((rs) => rs.first['n'] as int? ?? 0),
    );
  }

  /// One-shot lookup of the exercise trained in the most recent working set,
  /// for Progress's default target. Not a watch — call once on open.
  Future<String?> lastTrainedExerciseId() async {
    final rs = await db.getAll(
      'SELECT s.exercise_id '
      'FROM reps_compat1_legacy_local s '
      'JOIN sessions se ON se.id = s.session_id '
      'WHERE s.deleted=0 AND se.deleted=0 AND s.is_warmup = 0 '
      'ORDER BY se.date DESC, s.set_number DESC '
      'LIMIT 1',
    );
    if (rs.isEmpty) {
      return null;
    }
    return rs.first['exercise_id'] as String?;
  }

  // ── Profile header ────────────────────────────────────────────────────────

  /// First logged session date (YYYY-MM-DD, or null with no sessions) and the
  /// number of the user's own training days.
  ///
  /// The days filter `is_template IS NOT 1`, as `watchDays` does: synced
  /// template days stay in the local DB next to their absorbed copies, so a
  /// raw count would double them (NULL counts as owned). The query always
  /// returns exactly one row, so an empty DB emits `(null, 0)`.
  Stream<({String? firstSessionDate, int dayCount})> watchTrainingSummary() {
    // Name both tables explicitly so a days-only change refreshes the line.
    return reListenable(
      () => db
          .watch(
            'SELECT (SELECT MIN(date) FROM sessions WHERE deleted=0) AS first, '
            '(SELECT COUNT(*) FROM day_templates WHERE deleted=0 AND is_template IS NOT 1) AS days',
          )
          .map(
            (rs) => (
              firstSessionDate: rs.first['first'] as String?,
              dayCount: rs.first['days'] as int? ?? 0,
            ),
          ),
    );
  }

  // ── List streams ──────────────────────────────────────────────────────────

  /// Live stream of the most-recent [limit] PR sets, newest session first.
  ///
  /// `weight_kg` is TEXT on the client; the CAST produces a real value
  /// aliased as `weight`.
  Stream<List<({String exerciseId, double? weight, int? reps, String date})>>
  watchRecentPrs({int limit = 6}) {
    return reListenable(
      () => db
          .watch(
            'SELECT s.exercise_id, s.weight_kg, '
            's.reps, se.date '
            'FROM reps_compat1_legacy_local s '
            'JOIN sessions se ON se.id = s.session_id '
            'WHERE s.deleted=0 AND se.deleted=0 AND s.legacy_local_pr = 1 AND s.is_warmup = 0 '
            'ORDER BY se.date DESC, se.created_at DESC '
            'LIMIT ?',
            parameters: [limit],
          )
          .map(
            (rs) => rs
                .map(
                  (row) => (
                    exerciseId: row['exercise_id'] as String,
                    weight:
                        DecimalEvidence.fromRow(row, 'weight_kg').state ==
                                ValueState.valid &&
                            DecimalEvidence.fromRow(
                                  row,
                                  'weight_kg',
                                ).exact!.displayDouble?.isFinite ==
                                true
                        ? DecimalEvidence.fromRow(
                            row,
                            'weight_kg',
                          ).exact!.displayDouble
                        : null,
                    reps: row['reps'] is int ? row['reps'] as int : null,
                    date: row['date']?.toString() ?? '',
                  ),
                )
                .toList(),
          ),
    );
  }

  /// Live stream of working-set volume by muscle group since [weekStart].
  Stream<WeeklyMuscleVolume> watchWeeklyVolumeByMuscle({
    required DateTime weekStart,
  }) {
    return reListenable(
      () => db
          .watch(
            'SELECT ex.muscle_group AS muscle, COUNT(*) AS sets '
            'FROM reps_compat1_legacy_local s '
            'JOIN sessions se ON se.id = s.session_id '
            'JOIN exercises ex ON ex.id = s.exercise_id '
            'WHERE s.deleted=0 AND se.deleted=0 AND s.is_warmup = 0 AND $_qualifiedStatsDay AND se.date >= ? '
            'GROUP BY ex.muscle_group '
            'ORDER BY sets DESC',
            parameters: [isoDate(weekStart)],
          )
          .map((rows) {
            final groups = <({String muscle, int sets})>[];
            var unknownSets = 0;
            for (final row in rows) {
              final muscle = row['muscle'];
              final sets = row['sets'] as int;
              if (muscle == null) {
                unknownSets += sets;
              } else {
                // The accepted text projection includes custom and empty labels.
                groups.add((muscle: muscle as String, sets: sets));
              }
            }
            return WeeklyMuscleVolume(groups: groups, unknownSets: unknownSets);
          }),
    );
  }
}
