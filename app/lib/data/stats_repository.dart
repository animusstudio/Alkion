import 'package:flutter/foundation.dart' show visibleForTesting;

import '../store/local_store.dart';

import '../util/calendar_keys.dart';
import 're_listenable.dart';
import 'volume_attribution.dart';
import '../domain/evidence.dart';
import '../domain/catalog_execution.dart';
import 'catalog_load_history.dart';

// Qualification for the pinned SQLite calendar projection. Equality rejects
// SQLite rollover normalization; the original date text stays in its record.
const _qualifiedStatsDay =
    "length(se.date)=10 AND se.date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND se.date>='0001-01-01' AND date(se.date)=se.date";

/// Labeled weekly working sets and the sets whose muscle is unavailable.
/// Unknown evidence is deliberately separate from canonical/custom labels.
///
/// [groups] holds sets whose exercise has a legacy `muscle_group`. Sets with
/// an empty or missing one are [unlabeled], per exercise and with the catalog
/// variant its catalog binding links to, and count in [unknownSets]
/// until [attribute] gives them their catalog target groups.
final class WeeklyMuscleVolume {
  WeeklyMuscleVolume({
    required List<({String muscle, int sets})> groups,
    required this.unknownSets,
    List<({String exerciseId, String? variantId, int sets})> unlabeled =
        const [],
  }) : groups = List.unmodifiable(groups),
       unlabeled = List.unmodifiable(unlabeled);
  final List<({String muscle, int sets})> groups;
  final int unknownSets;
  final List<({String exerciseId, String? variantId, int sets})> unlabeled;

  /// Counts each [unlabeled] exercise's sets once for each group [targets]
  /// gives it; groups matching a legacy label merge with it. Sets with no
  /// target group stay unknown. Derived at read time: nothing is stored.
  WeeklyMuscleVolume attribute(VolumeTargets targets) {
    final totals = <String, int>{for (final g in groups) g.muscle: g.sets};
    final unknown = <({String exerciseId, String? variantId, int sets})>[];
    var unknownSets = 0;
    for (final row in unlabeled) {
      final groups = targets(row.exerciseId, row.variantId);
      if (groups.isEmpty) {
        unknown.add(row);
        unknownSets += row.sets;
        continue;
      }
      for (final group in groups) {
        totals[group] = (totals[group] ?? 0) + row.sets;
      }
    }
    return WeeklyMuscleVolume(
      groups: [for (final e in totals.entries) (muscle: e.key, sets: e.value)],
      unknownSets: unknownSets,
      unlabeled: unknown,
    );
  }
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

  /// Live count of PR sets logged since [weekStart]: legacy PRs by their
  /// local flag and catalog PRs by their stored derived result ([setPrSql]).
  Stream<int> watchPrsThisWeek({required DateTime weekStart}) {
    return reListenable(
      () => db
          .watch(
            'SELECT COUNT(*) AS n '
            'FROM reps_compat1_legacy_local s '
            'JOIN sessions se ON se.id = s.session_id AND se.profile_id = s.profile_id '
            'WHERE s.deleted=0 AND se.deleted=0 AND $setPrSql = 1 AND $_qualifiedStatsDay AND se.date >= ?',
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

  /// Live stream of the most-recent [limit] PR sets, newest session first:
  /// legacy PRs and catalog PRs ([setPrSql]).
  ///
  /// A legacy set's load and reps come from its exact `weight_kg`/`reps`
  /// evidence; a catalog set's from its stored catalog set bytes, decoded as
  /// [catalogLoadObservations] does. An unavailable value is null, never 0.
  Stream<List<({String exerciseId, double? weight, int? reps, String date})>>
  watchRecentPrs({int limit = 6}) {
    return reListenable(
      () => db
          .watch(
            // `s.*` rather than naming `catalog_set_bytes`: a store from
            // before catalog execution has no such column, and its sets are
            // all legacy.
            'SELECT s.*, se.date '
            'FROM reps_compat1_legacy_local s '
            'JOIN sessions se ON se.id = s.session_id AND se.profile_id = s.profile_id '
            'WHERE s.deleted=0 AND se.deleted=0 AND s.is_warmup = 0 AND $setPrSql = 1 '
            'ORDER BY se.date DESC, se.created_at DESC '
            'LIMIT ?',
            parameters: [limit],
          )
          .map((rs) => rs.map(recentPrFromRow).toList()),
    );
  }

  /// One Recent PRs row. A catalog set's load and reps come from its stored
  /// set bytes; bytes that cannot be decoded make that row's values
  /// unavailable (null, never 0) without failing the other rows.
  @visibleForTesting
  static ({String exerciseId, double? weight, int? reps, String date})
  recentPrFromRow(Map<String, dynamic> row) {
    final date = row['date']?.toString() ?? '';
    final exerciseId = row['exercise_id'] as String;
    if (row['catalog_set_bytes'] != null) {
      double? weight;
      int? reps;
      try {
        final metrics = CatalogSetEvidence.fromJson(
          decodeCatalogBytes(row['catalog_set_bytes']!),
        ).metrics;
        final load = metrics['reported_load']?.loadKg?.displayDouble;
        weight = load != null && load.isFinite ? load : null;
        final repetition = metrics['repetitions'];
        reps = repetition?.state == ValueState.valid
            ? int.tryParse(repetition!.raw.toString())
            : null;
      } catch (_) {
        weight = null;
        reps = null;
      }
      return (exerciseId: exerciseId, weight: weight, reps: reps, date: date);
    }
    final weight = DecimalEvidence.fromRow(row, 'weight_kg');
    final display = weight.state == ValueState.valid
        ? weight.exact!.displayDouble
        : null;
    return (
      exerciseId: exerciseId,
      weight: display != null && display.isFinite ? display : null,
      reps: row['reps'] is int ? row['reps'] as int : null,
      date: date,
    );
  }

  /// Live stream of working-set volume by muscle group since [weekStart].
  ///
  /// Grouped per exercise so that exercises without a legacy group keep
  /// their identity and catalog link for [WeeklyMuscleVolume.attribute]. The
  /// link is the exercise's catalog binding (one per exercise, read-only
  /// here); a store from before catalog execution has none, so it reports no
  /// variants instead of failing.
  Stream<WeeklyMuscleVolume> watchWeeklyVolumeByMuscle({
    required DateTime weekStart,
  }) {
    return reListenable(
      () => Stream.fromFuture(_hasCatalogBindings()).asyncExpand(
        (linked) => db
            .watch(
              'SELECT ex.muscle_group AS muscle, ex.id AS exercise_id, '
              'COUNT(*) AS sets, '
              '${linked ? _bindingVariantSql : 'NULL'} AS variant_id '
              'FROM reps_compat1_legacy_local s '
              'JOIN sessions se ON se.id = s.session_id '
              'JOIN exercises ex ON ex.id = s.exercise_id '
              'WHERE s.deleted=0 AND se.deleted=0 AND s.is_warmup = 0 AND $_qualifiedStatsDay AND se.date >= ? '
              'GROUP BY ex.id '
              'ORDER BY sets DESC',
              parameters: [if (linked) db.profileId, isoDate(weekStart)],
            )
            .map((rows) {
              final totals = <String, int>{};
              final unlabeled =
                  <({String exerciseId, String? variantId, int sets})>[];
              var unknownSets = 0;
              for (final row in rows) {
                final muscle = row['muscle'] as String?;
                final sets = row['sets'] as int;
                if (hasLegacyGroup(muscle)) {
                  // The accepted text projection includes custom labels.
                  totals[muscle!] = (totals[muscle] ?? 0) + sets;
                } else {
                  unknownSets += sets;
                  unlabeled.add((
                    exerciseId: row['exercise_id'] as String,
                    variantId: row['variant_id'] as String?,
                    sets: sets,
                  ));
                }
              }
              return WeeklyMuscleVolume(
                groups: [
                  for (final e in totals.entries)
                    (muscle: e.key, sets: e.value),
                ],
                unknownSets: unknownSets,
                unlabeled: unlabeled,
              );
            }),
      ),
    );
  }

  /// The variant of the exercise's live catalog binding: one indexed lookup,
  /// fetched for every exercise so that only Dart's [hasLegacyGroup] decides
  /// whether a label counts (SQL `trim` would only strip spaces).
  static const _bindingVariantSql =
      '(SELECT b.variant_id FROM exercise_catalog_bindings b '
      'WHERE b.profile_id=? AND b.exercise_id=ex.id AND b.deleted=0 '
      "AND b.catalog_namespace='$volumeCatalogNamespace')";

  Future<bool> _hasCatalogBindings() async =>
      await db.getOptional(
        "SELECT 1 AS present FROM sqlite_master WHERE type='table' "
        "AND name='exercise_catalog_bindings'",
      ) !=
      null;
}
