import 'package:powersync/powersync.dart';
import 'package:sqlite_async/sqlite_async.dart';

import '../capture/source_write_gate.dart';
import 'models.dart';
import 're_listenable.dart';
import 'top_set_backfill.dart';

// ── Mutation builders (pure) ──────────────────────────────────────────────────
//
// These build the SQL + args for editing logged history. They never touch
// is_top_set / is_pr — the server recomputes those on sync.

({String sql, List<Object?> args}) updateSetOp(String id,
        {required String weightKg, required int reps, required int? rir}) =>
    (
      sql: 'UPDATE sets SET weight_kg = ?, reps = ?, rir = ? WHERE id = ?',
      args: [weightKg, reps, rir, id]
    );

({String sql, List<Object?> args}) insertSetOp(String id,
        {required String sessionId,
        required String exerciseId,
        required int setNumber,
        required String weightKg,
        required int reps,
        required int? rir,
        required bool isWarmup}) =>
    (
      sql: 'INSERT INTO sets (id, session_id, exercise_id, set_number, weight_kg, reps, rir, is_warmup, is_top_set, is_pr) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      args: [
        id,
        sessionId,
        exerciseId,
        setNumber,
        weightKg,
        reps,
        isWarmup ? null : rir,
        isWarmup ? 1 : 0,
        0,
        0
      ]
    );

({String sql, List<Object?> args}) deleteSetOp(String id) =>
    (sql: 'DELETE FROM sets WHERE id = ?', args: [id]);

({String sql, List<Object?> args}) deleteSessionOp(String id) =>
    (sql: 'DELETE FROM sessions WHERE id = ?', args: [id]);

/// Groups a flat list of [LoggedSet]s into [ExerciseBlockData] records, one
/// per unique exercise, in the order they first appear. Pure — usable without
/// a repository (History's card body).
List<ExerciseBlockData> groupSetsIntoBlocks(List<LoggedSet> sets) {
  final order = <String>[];
  final byExercise = <String, List<LoggedSet>>{};

  for (final s in sets) {
    if (!byExercise.containsKey(s.exerciseId)) {
      order.add(s.exerciseId);
      byExercise[s.exerciseId] = [];
    }
    byExercise[s.exerciseId]!.add(s);
  }

  return order.map((exId) {
    final exSets = byExercise[exId]!;
    final workingSets = exSets.where((s) => !s.isWarmup).toList();

    // Top set: the one flagged is_top_set=true by the server; fall back to
    // the set with the highest weight if none is flagged.
    final topSet = workingSets.firstWhere(
      (s) => s.isTopSet,
      orElse: () => workingSets.isEmpty ? exSets.first : workingSets.reduce(
        (a, b) => a.weightKg >= b.weightKg ? a : b,
      ),
    );

    return ExerciseBlockData(
      exerciseId: exId,
      sets: exSets,
      topWeight: topSet.weightKg,
      topReps: topSet.reps,
      isPr: topSet.isPr,
    );
  }).toList();
}

/// `SELECT` of every set column plus `first_set`, the lowest set_number of
/// the set's exercise within its session — the key that orders a session's
/// exercises in workout order. Callers append their `WHERE` (on alias `s`)
/// and `ORDER BY first_set, s.exercise_id, s.set_number`.
const workoutOrderSelect =
    'SELECT s.*, (SELECT MIN(f.set_number) FROM sets f '
    'WHERE f.session_id = s.session_id AND f.exercise_id = s.exercise_id) AS first_set '
    'FROM sets s';

/// Repository for sessions and sets — history reads, last/best top-set lookups.
///
/// Local SQLite CAN JOIN freely; only the PowerSync sync-rules cannot. All
/// JOINs here query the local SQLite DB via [PowerSyncDatabase].
class SessionRepository {
  final PowerSyncDatabase db;

  const SessionRepository(this.db);

  // ── Top-set lookups ───────────────────────────────────────────────────────

  /// Returns the most-recent top set for [exerciseId], optionally restricted
  /// to sessions strictly before [beforeDate] (ISO-8601 date string), and
  /// optionally ignoring one session's rows ([excludeSessionId] — a resumed
  /// workout's own finished rows, which must not become its own baseline).
  ///
  /// The `created_at` DESC tie-break makes same-date results deterministic.
  Future<({double weight, int reps, String date})?> lastTopSet(
    String exerciseId, {
    String? beforeDate,
    String? excludeSessionId,
  }) async {
    final args = <Object?>[exerciseId];
    var filters = '';
    if (beforeDate != null) {
      filters += ' AND se.date < ?';
      args.add(beforeDate);
    }
    if (excludeSessionId != null) {
      filters += ' AND s.session_id != ?';
      args.add(excludeSessionId);
    }
    final row = await db.getOptional('''
        SELECT s.weight_kg, s.reps, se.date
          FROM sets s
          JOIN sessions se ON se.id = s.session_id
         WHERE s.exercise_id = ?
           AND s.is_top_set = 1
           AND s.is_warmup = 0$filters
         ORDER BY se.date DESC, se.created_at DESC
         LIMIT 1
      ''', args);
    if (row == null) return null;

    final wt = row['weight_kg'];
    return (
      weight: double.tryParse(wt?.toString() ?? '') ?? 0.0,
      reps: row['reps'] as int? ?? 0,
      date: row['date'] as String? ?? '',
    );
  }

  /// Returns the all-time best top-set weight (kg) for [exerciseId], or null
  /// if the exercise has never been logged. [excludeSessionId] ignores one
  /// session's rows (a resumed workout's own finished rows).
  Future<double?> bestTopSet(String exerciseId, {String? excludeSessionId}) async {
    final row = await db.getOptional(
      'SELECT MAX(CAST(weight_kg AS REAL)) AS best '
      'FROM sets WHERE exercise_id = ? AND is_top_set = 1 AND is_warmup = 0'
      '${excludeSessionId != null ? ' AND session_id != ?' : ''}',
      [exerciseId, if (excludeSessionId != null) excludeSessionId],
    );
    if (row == null) return null;
    final best = row['best'];
    if (best == null) return null;
    return (best as num).toDouble();
  }

  // ── User id ───────────────────────────────────────────────────────────────

  /// Returns the user_id from any synced session row, or null if no sessions
  /// exist yet.  Used to seed per-user data (e.g. muscle targets) when an
  /// auth identity is not threaded through the widget tree.
  Future<String?> anyUserId() async =>
      (await db.getOptional('SELECT user_id FROM sessions LIMIT 1'))?['user_id']
          as String?;

  // ── Session list ──────────────────────────────────────────────────────────

  /// A live stream of all sessions with aggregated stats (exercise count,
  /// PR count, tonnage), ordered newest first.
  ///
  /// Uses a LEFT JOIN so sessions with no sets still appear. `pr_count` counts
  /// distinct exercises where any set is a PR. `tonnage` excludes warm-up sets.
  Stream<List<HistorySessionRow>> watchSessionStats() =>
      reListenable(() => db.watch(
            '''SELECT se.id, se.date, se.split_label, se.duration_min,
                  COUNT(DISTINCT s.exercise_id) AS ex_count,
                  COUNT(DISTINCT CASE WHEN s.is_pr = 1 THEN s.exercise_id END) AS pr_count,
                  COALESCE(SUM(CASE WHEN s.is_warmup = 0 THEN CAST(s.weight_kg AS REAL) * s.reps ELSE 0 END), 0) AS tonnage
             FROM sessions se LEFT JOIN sets s ON s.session_id = se.id
            GROUP BY se.id, se.date, se.split_label, se.duration_min
            ORDER BY se.date DESC''',
          ).map((rs) => rs.map(HistorySessionRow.fromRow).toList()));

  /// A live stream of the most-recent [limit] sessions, newest first.
  Stream<List<SessionSummaryRow>> watchRecentSessions({int limit = 30}) {
    return reListenable(() => db
        .watch(
          'SELECT id, date, split_label, day_template_id, duration_min '
          'FROM sessions ORDER BY date DESC, created_at DESC LIMIT ?',
          parameters: [limit],
        )
        .map((rs) => rs.map(SessionSummaryRow.fromRow).toList()));
  }

  /// One session row, or null if it no longer exists.
  Future<SessionSummaryRow?> sessionById(String id) async {
    final row = await db.getOptional(
      'SELECT id, date, split_label, day_template_id, duration_min '
      'FROM sessions WHERE id = ?',
      [id],
    );
    return row == null ? null : SessionSummaryRow.fromRow(row);
  }

  // ── Set reads ─────────────────────────────────────────────────────────────

  /// Returns all sets for a session in workout order: exercises by their
  /// first (lowest) set_number, then each exercise's sets by set_number.
  ///
  /// finish() numbers sets continuously across the workout, so this is the
  /// order the exercises were done in. Sessions from older builds numbered
  /// sets per exercise (every exercise starts at 1); those ties fall back to
  /// exercise_id, the order they always showed in.
  Future<List<LoggedSet>> setsForSession(String sessionId) async {
    final rows = await db.getAll(
      '$workoutOrderSelect WHERE s.session_id = ? '
      'ORDER BY first_set, s.exercise_id, s.set_number',
      [sessionId],
    );
    return rows.map(LoggedSet.fromRow).toList();
  }

  /// See [groupSetsIntoBlocks].
  List<ExerciseBlockData> groupIntoBlocks(List<LoggedSet> sets) =>
      groupSetsIntoBlocks(sets);

  // ── Edit / delete (history) ───────────────────────────────────────────────

  /// Re-derive is_top_set for one (session,exercise) group: clear all, then flag
  /// the heaviest non-warmup set. Keeps Progress correct after offline edits.
  Future<void> _recomputeTopSet(
      SqliteWriteContext tx, String sessionId, String exerciseId) async {
    final rows = await tx.getAll(
        'SELECT id, weight_kg, reps, set_number, is_warmup FROM sets WHERE session_id = ? AND exercise_id = ?',
        [sessionId, exerciseId]);
    await tx.execute(
        'UPDATE sets SET is_top_set = 0 WHERE session_id = ? AND exercise_id = ?',
        [sessionId, exerciseId]);
    final topId = heaviestNonWarmupId(
        rows.map((r) => Map<String, Object?>.from(r)).toList());
    if (topId != null) {
      await tx.execute('UPDATE sets SET is_top_set = 1 WHERE id = ?', [topId]);
    }
  }

  /// Updates a single set's weight/reps/rir, then re-derives the group's
  /// is_top_set so offline Progress stays correct. Leaves is_pr alone.
  Future<void> updateSet(
    String id, {
    required String weightKg,
    required int reps,
    required int? rir,
  }) async {
    final op = updateSetOp(id, weightKg: weightKg, reps: reps, rir: rir);
    await runSourceWrite(
      'history.update_set',
      (_) => db.writeTransaction((tx) async {
        await tx.execute(op.sql, op.args);
        final g = await tx.getOptional(
            'SELECT session_id, exercise_id FROM sets WHERE id = ?', [id]);
        if (g != null) {
          await _recomputeTopSet(
              tx, g['session_id'] as String, g['exercise_id'] as String);
        }
      }),
    );
  }

  /// Appends a set to (sessionId, exerciseId); re-derives the group's top set.
  /// Returns the new set's id.
  Future<String> addSet(
    String sessionId,
    String exerciseId, {
    required String weightKg,
    required int reps,
    required int? rir,
    required bool isWarmup,
  }) async {
    final id = uuid.v4();
    await runSourceWrite('history.add_set', (_) => db.writeTransaction((tx) async {
      // Session-wide, not per exercise: set_number carries the workout's
      // exercise order, so a set added here stays after everything logged —
      // a set added to an existing exercise keeps its place, and an exercise
      // first added from History sorts last instead of first.
      final row = await tx.getOptional(
          'SELECT MAX(set_number) AS m FROM sets WHERE session_id = ?',
          [sessionId]);
      final nextNum = ((row?['m'] as int?) ?? 0) + 1;
      final op = insertSetOp(id,
          sessionId: sessionId,
          exerciseId: exerciseId,
          setNumber: nextNum,
          weightKg: weightKg,
          reps: reps,
          rir: rir,
          isWarmup: isWarmup);
      await tx.execute(op.sql, op.args);
      await _recomputeTopSet(tx, sessionId, exerciseId);
    }));
    return id;
  }

  /// Deletes a single set by id, then re-derives the group's is_top_set so
  /// offline Progress stays correct.
  Future<void> deleteSet(String id) async {
    await runSourceWrite('history.delete_set', (_) => db.writeTransaction((tx) async {
      final g = await tx.getOptional(
          'SELECT session_id, exercise_id FROM sets WHERE id = ?',
          [id]); // BEFORE delete
      await tx.execute(deleteSetOp(id).sql, deleteSetOp(id).args);
      if (g != null) {
        await _recomputeTopSet(
            tx, g['session_id'] as String, g['exercise_id'] as String);
      }
    }));
  }

  /// Deletes a whole session and its sets. [parent] when the delete is part
  /// of a larger operation (History's delete, which also forgets the
  /// session's finished snapshot).
  Future<void> deleteSession(String id, {SourceTicket? parent}) async {
    await runSourceWrite(
      'history.delete_session',
      (_) => db.writeTransaction((tx) async {
        await tx.execute(
            'DELETE FROM sets WHERE session_id = ?', [id]); // clean local view
        await tx.execute('DELETE FROM sessions WHERE id = ?', [id]);
      }),
      parent: parent,
    );
  }
}
