import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../store/local_store.dart';
import '../domain/local_action.dart';
import '../domain/evidence.dart';
import 'exercise_repository.dart';
import 'session_writer.dart';
import 'models.dart';
import 're_listenable.dart';
import 'top_set_backfill.dart';

// ── Mutation builders (pure) ──────────────────────────────────────────────────
//
// These build the SQL + args for editing logged history. They never touch
// is_top_set / is_pr; derivation is a separate local workflow/evidence concern.

({String sql, List<Object?> args}) updateSetOp(
  String id, {
  required String weightKg,
  required int reps,
  required int? rir,
}) => (
  sql: 'UPDATE sets SET weight_kg = ?, reps = ?, rir = ? WHERE id = ?',
  args: [weightKg, reps, rir, id],
);

({String sql, List<Object?> args}) insertSetOp(
  String id, {
  required String sessionId,
  required String exerciseId,
  required int setNumber,
  required String weightKg,
  required int reps,
  required int? rir,
  required bool isWarmup,
}) => (
  sql:
      'INSERT INTO sets (id, session_id, exercise_id, set_number, weight_kg, reps, rir, is_warmup, is_top_set, is_pr) '
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
    0,
  ],
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

    // Top set: the retained is_top_set flag, falling back to
    // the set with the highest weight if none is flagged.
    final topSet = workingSets.firstWhere(
      (s) => s.isTopSet,
      orElse: () => workingSets.isEmpty
          ? exSets.first
          : workingSets.reduce((a, b) => a.weightKg >= b.weightKg ? a : b),
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
    'SELECT s.*, (SELECT revision FROM sessions se WHERE se.profile_id=s.profile_id AND se.id=s.session_id) AS workout_revision, (SELECT MIN(f.set_number) FROM sets f '
    'WHERE f.session_id = s.session_id AND f.exercise_id = s.exercise_id AND f.deleted=0) AS first_set '
    'FROM reps_compat1_legacy_local s';

/// Repository for sessions and sets — history reads, last/best top-set lookups.
///
/// Queries and JOINs use the profile-scoped local [LocalDatabase].
class SessionRepository {
  final LocalDatabase db;

  SessionRepository.local(this.db);
  final _observedSets = <String, Map<String, dynamic>>{};
  final _sessionBases = <String, int>{};
  final _pending = <String, PreparedDomainAction>{};

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
  }) => db.readTransaction((tx) async {
    final rows = await _orderRows(
      tx,
      'last:$exerciseId',
      beforeDate: beforeDate,
      excludeSessionId: excludeSessionId,
    );
    final row = await _chooseOrder(
      tx,
      'last:$exerciseId',
      rows,
      beforeDate: beforeDate,
      excludeSessionId: excludeSessionId,
    );
    if (row == null) {
      return null;
    }
    final evidence = DecimalEvidence.fromRow(row, 'weight_kg');
    final value = evidence.exact?.displayDouble;
    if (evidence.state != ValueState.valid ||
        value == null ||
        !value.isFinite ||
        row['reps'] is! int ||
        row['set_number'] is! int) {
      throw const StoreException('baseline_value_unavailable');
    }
    return (
      weight: value,
      reps: row['reps'] as int,
      date: row['date']?.toString() ?? '',
    );
  });

  /// Preserves absence versus a recorded but unusable reference. Composing the
  /// virtual valid-record API keeps existing repository adapters meaningful.
  Future<LastTopReference> lastTopSetEvidence(
    String exerciseId, {
    String? beforeDate,
    String? excludeSessionId,
  }) async {
    try {
      return LastTopReference(
        await lastTopSet(
          exerciseId,
          beforeDate: beforeDate,
          excludeSessionId: excludeSessionId,
        ),
      );
    } on StoreException catch (error) {
      if (error.category != 'baseline_value_unavailable') rethrow;
      return const LastTopReference.unavailable();
    }
  }

  Future<List<Map<String, dynamic>>> _orderRows(
    LocalRead tx,
    String scope, {
    String? beforeDate,
    String? excludeSessionId,
  }) {
    if (scope == 'rotation') {
      return tx.getAll(
        "SELECT id AS session_id,revision,date,created_at,day_template_id,split_label FROM sessions WHERE profile_id=? AND deleted=0 AND day_template_id IS NOT NULL ORDER BY date DESC,CASE WHEN created_at IS NULL OR created_at='' THEN 0 ELSE 1 END,created_at DESC,id DESC",
        [tx.profileId],
      );
    }
    final exercise = scope.substring(5);
    return tx
        .getAll(
          "SELECT s.id,s.revision,s.session_id,s.weight_kg,s.reps,s.set_number,se.revision AS workout_revision,se.date,se.created_at,se.split_label FROM reps_compat1_legacy_local s JOIN sessions se ON se.id=s.session_id AND se.profile_id=s.profile_id WHERE s.profile_id=? AND s.deleted=0 AND se.deleted=0 AND s.exercise_id=? AND s.legacy_local_top=1 AND s.is_warmup=0"
          "${excludeSessionId == null ? '' : ' AND s.session_id!=?'} ORDER BY se.date DESC,CASE WHEN se.created_at IS NULL OR se.created_at='' THEN 0 ELSE 1 END,se.created_at DESC,se.id DESC,s.id",
          [
            tx.profileId,
            exercise,
            if (excludeSessionId != null) excludeSessionId,
          ],
        )
        .then(
          (rows) => rows
              .where(
                (row) =>
                    !hasQualifiedCalendarDay(row['date']?.toString()) ||
                    beforeDate == null ||
                    (row['date'] as String).compareTo(beforeDate) < 0,
              )
              .toList(),
        );
  }

  Future<Map<String, dynamic>?> _chooseOrder(
    LocalRead tx,
    String scope,
    List<Map<String, dynamic>> rows, {
    String? beforeDate,
    String? excludeSessionId,
  }) async {
    if (rows.isEmpty) {
      return null;
    }
    final unavailableDays = rows.any(
      (r) => !hasQualifiedCalendarDay(r['date']?.toString()),
    );
    final latest = unavailableDays
        ? rows
        : rows.where((r) => r['date'] == rows.first['date']).toList();
    final instants = [
      for (final row in latest) TimeEvidence.fromRow(row, 'created_at'),
    ];
    final qualified = instants.every((t) => t.kind == TimeKind.offsetInstant);
    final ordered = [...latest];
    if (qualified) {
      ordered.sort(
        (a, b) => _compareInstants(
          b['created_at'] as String,
          a['created_at'] as String,
        ),
      );
    }
    final tied =
        qualified &&
        [
          for (var i = 1; i < ordered.length; i++)
            _compareInstants(
                  ordered[i - 1]['created_at'] as String,
                  ordered[i]['created_at'] as String,
                ) ==
                0,
        ].any((t) => t);
    final uncertain =
        unavailableDays || latest.length > 1 && (!qualified || tied);
    if (!uncertain) {
      return ordered.first;
    }
    final fingerprint = sha256
        .convert(
          localBytes({
            'scope': scope,
            'beforeDate': beforeDate,
            'excludeSessionId': excludeSessionId,
            'inputs': rows,
          }),
        )
        .toString();
    final preference = await tx.localState(
      LocalStateKind.orderResolution,
      scope,
    );
    if (preference != null) {
      final value =
          jsonDecode(
                utf8.decode((preference['payload_bytes'] as List).cast<int>()),
              )
              as Map;
      if (value['fingerprint'] == fingerprint) {
        for (final row in latest) {
          if (row['session_id'] == value['chosenSessionId']) {
            return row;
          }
        }
      }
    }
    throw HistoryOrderReview(
      scope,
      fingerprint,
      latest,
      beforeDate: beforeDate,
      excludeSessionId: excludeSessionId,
    );
  }

  Future<String?> lastDayForRotation() => db.readTransaction((tx) async {
    final rows = await _orderRows(tx, 'rotation');
    return (await _chooseOrder(tx, 'rotation', rows))?['day_template_id']
        as String?;
  });
  Future<void> resolveOrder(HistoryOrderReview review, String chosenSessionId) {
    final token = db.token;
    final chosen = chosenSessionId;
    if (!review.choices.any((r) => r['session_id'] == chosen)) {
      return Future.error(const StoreException('invalid_order_choice'));
    }
    return db.writeTransaction((tx) async {
      final rows = await _orderRows(
        tx,
        review.scope,
        beforeDate: review.beforeDate,
        excludeSessionId: review.excludeSessionId,
      );
      final fingerprint = sha256
          .convert(
            localBytes({
              'scope': review.scope,
              'beforeDate': review.beforeDate,
              'excludeSessionId': review.excludeSessionId,
              'inputs': rows,
            }),
          )
          .toString();
      if (fingerprint != review.fingerprint) {
        throw const StoreException('order_inputs_changed');
      }
      final value = {
        'scope': review.scope,
        'fingerprint': fingerprint,
        'chosenSessionId': chosen,
        'attribution': 'explicit_successor_preference',
        'historical_fact': false,
      };
      final old = await tx.localState(
        LocalStateKind.orderResolution,
        review.scope,
      );
      await tx.putLocalState(
        LocalStateKind.orderResolution,
        review.scope,
        localBytes(value),
        expectedRevision: old?['revision'] as int? ?? 0,
      );
      await tx.addReview(
        id: domainUuid.v4(),
        category: 'order_preference',
        evidence: localBytes({...value, 'inputs': rows}),
      );
    }, expected: token);
  }

  /// Returns the all-time best top-set weight (kg) for [exerciseId], or null
  /// if the exercise has never been logged. [excludeSessionId] ignores one
  /// session's rows (a resumed workout's own finished rows).
  Future<double?> bestTopSet(
    String exerciseId, {
    String? excludeSessionId,
  }) async {
    final rows = await db.getAll(
      'SELECT s.* FROM reps_compat1_legacy_local s JOIN sessions se ON se.id=s.session_id AND se.profile_id=s.profile_id WHERE s.deleted=0 AND se.deleted=0 AND s.exercise_id=? AND s.legacy_local_top=1 AND s.is_warmup=0 '
      '${excludeSessionId != null ? ' AND s.session_id!=?' : ''}',
      [exerciseId, if (excludeSessionId != null) excludeSessionId],
    );
    final values = rows
        .map((row) => DecimalEvidence.fromRow(row, 'weight_kg'))
        .where((e) => e.state == ValueState.valid)
        .map((e) => e.exact!.displayDouble)
        .whereType<double>()
        .where((v) => v.isFinite);
    double? best;
    for (final value in values) {
      if (best == null || value > best) {
        best = value;
      }
    }
    return best;
  }

  // ── User id ───────────────────────────────────────────────────────────────

  /// Returns the user_id from any synced session row, or null if no sessions
  /// exist yet.  Used to seed per-user data (e.g. muscle targets) when an
  /// auth identity is not threaded through the widget tree.
  Future<String?> anyUserId() async =>
      (await db.getOptional(
            'SELECT user_id FROM sessions WHERE deleted=0 LIMIT 1',
          ))?['user_id']
          as String?;

  // ── Session list ──────────────────────────────────────────────────────────

  /// A live stream of all sessions with aggregated stats (exercise count,
  /// PR count, tonnage), ordered newest first.
  ///
  /// Uses a LEFT JOIN so sessions with no sets still appear. `pr_count` counts
  /// distinct exercises where any set is a PR. `tonnage` excludes warm-up sets
  /// and is legacy SQL arithmetic, not for display; History volume comes from
  /// the exact evidence of the same `coverage_sets` rows.
  Stream<List<HistorySessionRow>> watchSessionStats() => reListenable(
    () => db
        .watch(
          '''SELECT se.id, se.revision, se.date, se.split_label, se.duration_min, CASE WHEN se.created_at IS NULL OR se.created_at='' OR EXISTS(SELECT 1 FROM sessions other WHERE other.profile_id=se.profile_id AND other.deleted=0 AND other.id!=se.id AND other.date=se.date AND (other.created_at IS NULL OR other.created_at=se.created_at)) THEN 1 ELSE 0 END AS order_uncertain,
                  json_group_array(json_object('id',s.id,'exercise_id',s.exercise_id,'set_number',s.set_number,'weight_kg',s.weight_kg,'reps',s.reps,'rir',s.rir,'is_warmup',s.is_warmup,'is_top_set',s.legacy_local_top,'is_pr',s.legacy_local_pr)) AS coverage_sets,
                  COUNT(DISTINCT s.exercise_id) AS ex_count,
                  COUNT(DISTINCT CASE WHEN s.legacy_local_pr = 1 THEN s.exercise_id END) AS pr_count,
                  COALESCE(SUM(CASE WHEN s.is_warmup = 0 THEN CAST(s.weight_kg AS REAL) * s.reps ELSE 0 END), 0) AS tonnage
             FROM sessions se LEFT JOIN reps_compat1_legacy_local s ON s.session_id = se.id AND s.deleted=0 AND s.profile_id=se.profile_id
            WHERE se.deleted=0
            GROUP BY se.id, se.date, se.split_label, se.duration_min
            ORDER BY se.date DESC, CASE WHEN se.created_at IS NULL OR se.created_at='' THEN 0 ELSE 1 END, se.created_at DESC,se.id DESC''',
        )
        .map(
          (rs) => rs.map((r) {
            final sets = (jsonDecode(r['coverage_sets'] as String) as List)
                .cast<Map>()
                .where((s) => s['id'] != null)
                .map((s) => LoggedSet.fromRow(Map<String, dynamic>.from(s)))
                .toList();
            final coverage = CompatibilityCoverage.sets(sets);
            final row = HistorySessionRow.fromRow(r);
            return HistorySessionRow(
              id: row.id,
              localRevision: row.localRevision,
              orderUncertain: row.orderUncertain,
              date: row.date,
              dateEvidence: row.dateEvidence,
              splitLabel: row.splitLabel,
              durationMin: row.durationMin,
              durationEvidence: row.durationEvidence,
              rawFields: row.rawFields,
              exerciseCount: row.exerciseCount,
              prCount: row.prCount,
              tonnageKg: row.tonnageKg,
              coverage: coverage,
              volumeEvidence: historyVolumeOf(sets),
            );
          }).toList(),
        ),
  );

  /// A live stream of the most-recent [limit] sessions, newest first.
  Stream<List<SessionSummaryRow>> watchRecentSessions({int limit = 30}) {
    return reListenable(
      () => db
          .watch(
            'SELECT id, date, split_label, day_template_id, original_day_id, duration_min, revision '
            'FROM sessions WHERE deleted=0 ORDER BY date DESC, created_at DESC,id DESC LIMIT ?',
            parameters: [limit],
          )
          .map((rs) => rs.map(SessionSummaryRow.fromRow).toList()),
    );
  }

  /// One session row, or null if it no longer exists.
  Future<SessionSummaryRow?> sessionById(String id) async {
    final row = await db.getOptional(
      'SELECT id, date, split_label, day_template_id, original_day_id, duration_min, revision '
      'FROM sessions WHERE deleted=0 AND id = ?',
      [id],
    );
    if (row != null && row['revision'] is int) {
      _sessionBases[id] = row['revision'] as int;
    }
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
      '$workoutOrderSelect WHERE s.deleted=0 AND s.session_id = ? '
      'ORDER BY first_set, s.exercise_id, s.set_number',
      [sessionId],
    );
    for (final row in rows) {
      _observedSets[row['id'] as String] = Map.from(row);
    }
    final session = await sessionById(sessionId);
    if (session == null) {
      throw const StoreException('deleted_target');
    }
    return rows.map(LoggedSet.fromRow).toList();
  }

  /// See [groupSetsIntoBlocks].
  List<ExerciseBlockData> groupIntoBlocks(List<LoggedSet> sets) =>
      groupSetsIntoBlocks(sets);

  // ── Edit / delete (history) ───────────────────────────────────────────────

  PreparedDomainAction prepareHistoryEdit(
    String sessionId,
    int base,
    Map<String, Object?> input, {
    String? operationId,
  }) => prepareDomain(
    db,
    RecordKind.workout,
    LocalActionKind.workoutEdit,
    sessionId,
    base,
    input,
    operationId: operationId,
  );
  PreparedDomainAction prepareDelete(
    String id,
    int revision, {
    bool restore = false,
  }) => prepareDomain(
    db,
    RecordKind.workout,
    restore ? LocalActionKind.workoutRestore : LocalActionKind.workoutDelete,
    id,
    revision,
    {},
  );
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
    final old = await observedRecord(
      tx,
      a.target,
      a.baseLocalRevision,
      allowDeleted: a.action == LocalActionKind.workoutRestore,
    );
    final fields = projectionFields(old);
    final rows = await tx.getAll(
      'SELECT * FROM reps_compat1_legacy_local WHERE profile_id=? AND session_id=? AND deleted=0',
      [tx.profileId, a.target.id],
    );
    if (a.action == LocalActionKind.workoutDelete ||
        a.action == LocalActionKind.workoutRestore) {
      final deleting = a.action == LocalActionKind.workoutDelete;
      if (!deleting && old['deleted'] != 1) {
        throw const StoreException('not_deleted');
      }
      final revision = await putDomain(
        tx,
        a.target,
        fields,
        deleted: deleting,
        sourceRevisionId: old['source_revision_id'] as String?,
      );
      // Sets retain their identities and evidence; workout tombstone scopes visibility.
      final recovery = await tx.localState(
        LocalStateKind.finishedRecovery,
        'last',
      );
      Object? recovered;
      if (recovery != null) {
        try {
          recovered = jsonDecode(
            utf8.decode((recovery['payload_bytes'] as List).cast<int>()),
          );
        } on FormatException {
          /* Preserve malformed/unrelated recovery bytes. */
        }
      }
      if (deleting &&
          recovery != null &&
          recovered is Map &&
          recovered['sessionId'] == a.target.id) {
        await tx.putLocalState(
          LocalStateKind.finishedRecovery,
          'last',
          Uint8List.fromList((recovery['payload_bytes'] as List).cast<int>()),
          expectedRevision: recovery['revision'] as int,
          status: 'review',
        );
      }
      return {'id': a.target.id, 'revision': revision};
    }
    if (a.action != LocalActionKind.workoutEdit) {
      throw const StoreException('unsupported_action');
    }
    final input = intent.input;
    final change = Map<String, dynamic>.from(input['set'] as Map);
    final id = change['id'] as String;
    final ref = LocalRef(tx.profileId, RecordKind.workoutSet, id);
    final previous = await tx.record(ref);
    final base = change['base'] as int;
    if ((previous?['revision'] ?? 0) != base ||
        previous?['deleted'] == 1 ||
        (previous != null && previous['session_id'] != a.target.id)) {
      throw const StoreException('revision_conflict');
    }
    if (previous == null && input['mode'] != 'add') {
      throw const StoreException('not_found');
    }
    final affectedExercise = previous?['exercise_id'] ?? change['exercise_id'];
    final ordinalRows = previous == null
        ? rows
        : rows.where(
            (r) =>
                r['exercise_id'] == affectedExercise &&
                (input['mode'] != 'delete' || r['id'] != id),
          );
    if (ordinalRows.any((r) => r['set_number'] is! int)) {
      throw const StoreException('set_order_review_required');
    }
    final next = previous == null
        ? <String, Object?>{
            'session_id': a.target.id,
            'exercise_id': change['exercise_id'],
            'set_number':
                rows.fold<int>(
                  0,
                  (n, r) => (r['set_number'] as int? ?? 0) > n
                      ? r['set_number'] as int
                      : n,
                ) +
                1,
            'is_warmup': change['is_warmup'],
            'is_top_set': 0,
            'is_pr': 0,
            'created_at': intent.createdAt,
          }
        : projectionFields(previous);
    final touched = Map<String, Object?>.from(change['fields'] as Map? ?? {});
    if (touched.keys.any((k) => !{'weight_kg', 'reps', 'rir'}.contains(k))) {
      throw const StoreException('invalid_projection_field');
    }
    next.addAll(touched);
    next['updated_at'] = intent.createdAt;
    final deleting = input['mode'] == 'delete';
    final ex = next['exercise_id'];
    if (previous == null) {
      final exercise = await tx.record(
        LocalRef(tx.profileId, RecordKind.exercise, ex as String),
      );
      if (exercise == null || exercise['deleted'] == 1) {
        throw const StoreException('missing_reference');
      }
    }
    await putDomain(
      tx,
      ref,
      next,
      deleted: deleting,
      sourceRevisionId: previous?['source_revision_id'] as String?,
    );
    final group = await tx.getAll(
      'SELECT * FROM reps_compat1_legacy_local WHERE profile_id=? AND session_id=? AND exercise_id=? AND deleted=0',
      [tx.profileId, a.target.id, ex],
    );
    final top = heaviestNonWarmupId(
      group.map((r) => Map<String, Object?>.from(r)).toList(),
    );
    final revisions = <String, int>{};
    for (final row in group) {
      var revision = row['revision'] as int;
      // Every derived result names the exact immutable input revision.
      if (row['id'] != id) {
        revision = await putDomain(
          tx,
          LocalRef(tx.profileId, RecordKind.workoutSet, row['id'] as String),
          projectionFields(row)
            ..remove('legacy_local_top')
            ..remove('legacy_local_pr'),
          sourceRevisionId: row['source_revision_id'] as String?,
        );
      }
      revisions[row['id'] as String] = revision;
      await writeCompatibleSet(
        tx,
        row['id'] as String,
        revision,
        top: row['id'] == top ? 1 : 0,
        pr: row['legacy_local_pr'] as int? ?? 0,
      );
    }
    final revision = await putDomain(
      tx,
      a.target,
      fields,
      sourceRevisionId: old['source_revision_id'] as String?,
    );
    return {
      'id': a.target.id,
      'revision': revision,
      'set_id': id,
      'sets': revisions,
    };
  }

  Future<LocalActionResult> _commitHistory(
    String key,
    PreparedDomainAction Function() prepare,
  ) async {
    final intent = _pending[key] ??= prepare();
    final outcome = await commitPrepared(intent);
    final result = jsonDecode(utf8.decode(outcome.bytes)) as Map;
    _sessionBases[intent.action.target.id] = result['revision'] as int;
    final changed = Map<String, dynamic>.from(result['sets'] as Map? ?? {});
    for (final entry in changed.entries) {
      _observedSets[entry.key]?['revision'] = entry.value;
    }
    if (identical(_pending[key], intent)) {
      _pending.remove(key);
    }
    return outcome;
  }

  Future<void> updateSet(
    String id, {
    required String weightKg,
    required int reps,
    required int? rir,
  }) {
    final row = _observedSets[id];
    if (row == null) {
      return Future.error(const StoreException('observed_revision_required'));
    }
    final sessionId = row['session_id'] as String,
        base = _sessionBases[row['session_id']];
    if (base == null) {
      return Future.error(const StoreException('observed_revision_required'));
    }
    final fields = <String, Object?>{
      if (double.tryParse(weightKg) !=
          (double.tryParse(row['weight_kg']?.toString() ?? '') ?? 0))
        'weight_kg': weightKg,
      if (reps != (row['reps'] ?? 0)) 'reps': reps,
      if (rir != row['rir']) 'rir': rir,
    };
    // Prepare executes synchronously inside _commitHistory before its first await.
    return _commitHistory(
      'set:$id',
      () => prepareHistoryEdit(sessionId, base, {
        'mode': 'edit',
        'set': {'id': id, 'base': row['revision'], 'fields': fields},
      }),
    ).then((_) {
      row.addAll(fields);
    });
  }

  Future<String> addSet(
    String sessionId,
    String exerciseId, {
    required String weightKg,
    required int reps,
    required int? rir,
    required bool isWarmup,
  }) {
    final base = _sessionBases[sessionId];
    if (base == null) {
      return Future.error(const StoreException('observed_revision_required'));
    }
    final existing = _pending['add:$sessionId'];
    final id = existing?.input['set']['id'] as String? ?? domainUuid.v4();
    return _commitHistory(
      'add:$sessionId',
      () => prepareHistoryEdit(sessionId, base, {
        'mode': 'add',
        'set': {
          'id': id,
          'base': 0,
          'exercise_id': exerciseId,
          'is_warmup': isWarmup ? 1 : 0,
          'fields': {
            'weight_kg': weightKg,
            'reps': reps,
            'rir': isWarmup ? null : rir,
          },
        },
      }),
    ).then((_) {
      _observedSets[id] = {
        'id': id,
        'revision': 1,
        'session_id': sessionId,
        'exercise_id': exerciseId,
        'weight_kg': weightKg,
        'reps': reps,
        'rir': rir,
      };
      return id;
    });
  }

  Future<void> deleteSet(String id) {
    final row = _observedSets[id];
    if (row == null) {
      return Future.error(const StoreException('observed_revision_required'));
    }
    final base = _sessionBases[row['session_id']];
    if (base == null) {
      return Future.error(const StoreException('observed_revision_required'));
    }
    return _commitHistory(
      'set:$id',
      () => prepareHistoryEdit(row['session_id'] as String, base, {
        'mode': 'delete',
        'set': {'id': id, 'base': row['revision']},
      }),
    ).then((_) {
      _observedSets.remove(id);
    });
  }

  Future<Map<String, int>> allSetBases(String sessionId) async => {
    for (final row in await db.getAll(
      'SELECT id,revision FROM sets WHERE session_id=?',
      [sessionId],
    ))
      row['id'] as String: row['revision'] as int,
  };
  Future<void> deleteSession(String id, {int? observedRevision}) async {
    if (observedRevision == null) {
      throw const StoreException('observed_revision_required');
    }
    // A confirmed selected-base deletion retains its identity through unknown
    // consumer outcomes and owed postcommit callbacks, including exact replay.
    final key = 'delete:$id:$observedRevision';
    final intent = _pending[key] ??= prepareDelete(id, observedRevision);
    await commitPrepared(intent);
  }
}

/// Deterministic history remains readable; only an affected Last/rotation
/// action asks for a revision-bound preference, never a reconstructed fact.
class HistoryOrderReview implements Exception {
  HistoryOrderReview(
    this.scope,
    this.fingerprint,
    List<Map<String, dynamic>> rows, {
    this.beforeDate,
    this.excludeSessionId,
  }) : choices = List.unmodifiable(
         rows.map((r) => Map<String, dynamic>.unmodifiable(r)),
       );
  final String scope, fingerprint;
  final String? beforeDate, excludeSessionId;
  final List<Map<String, dynamic>> choices;
  @override
  String toString() => 'History order needs an explicit choice ($scope)';
}

/// Only called after TimeEvidence has strictly qualified calendar/clock/offset.
/// Compare whole UTC seconds plus arbitrary source fractional precision; raw
/// lexical offset order and DateTime microsecond truncation are not chronology.
int _compareInstants(String a, String b) {
  (int, String) key(String text) {
    final fraction = RegExp(r'\.(\d+)(?=Z|[+-]\d{2}:\d{2}$)').firstMatch(text);
    final whole = fraction == null
        ? text
        : text.replaceRange(fraction.start, fraction.end, '');
    return (
      DateTime.parse(whole).microsecondsSinceEpoch ~/ 1000000,
      fraction?.group(1) ?? '',
    );
  }

  final x = key(a), y = key(b);
  final seconds = x.$1.compareTo(y.$1);
  if (seconds != 0) return seconds;
  final width = x.$2.length > y.$2.length ? x.$2.length : y.$2.length;
  return x.$2.padRight(width, '0').compareTo(y.$2.padRight(width, '0'));
}

class LastTopReference {
  const LastTopReference(this.value) : unavailable = false;
  const LastTopReference.unavailable() : value = null, unavailable = true;
  final ({double weight, int reps, String date})? value;
  final bool unavailable;
}
