import 'dart:convert';
import '../store/local_store.dart';
import '../domain/evidence.dart';
import '../domain/local_action.dart';
import 'exercise_repository.dart';

// ── SqlExecutor abstraction ───────────────────────────────────────────────────

/// Retained pure SQL builder seam. Application writes use prepared repository
/// actions below; call-recording builder tests are not persistence evidence.
abstract class SqlExecutor {
  Future<void> execute(String sql, [List<Object?> params = const []]);
}

/// Callback-scoped executor for retained pure helpers. Workflow mutation uses
/// WorkoutRepository.executePreparedInTransaction with the admitted action.
class LocalTxExecutor implements SqlExecutor {
  const LocalTxExecutor(this.tx);
  final LocalTransaction tx;
  @override
  Future<void> execute(String sql, [List<Object?> params = const []]) async =>
      tx.execute(sql, params);
}

// ── Data transfer objects ─────────────────────────────────────────────────────

/// Describes one set to be persisted at session finish.
class SetWrite {
  final String id;
  final String exerciseId;
  final int setNumber;

  /// Weight stored as TEXT (e.g. `'60.00'`) — consistent with the schema rule
  /// that NUMERIC columns are TEXT on the client.
  final Object? weightKg;

  final int reps;

  /// Untouched imported null/invalid/empty values remain evidence. The numeric
  /// fields above are explicitly the retained compatibility display fallback.
  final Map<String, Object?> rawUntouched;

  /// RIR is null for warm-up sets (not persisted; the server leaves it NULL).
  final int? rir;

  final bool isWarmup;

  final bool isTopSet;

  final bool isPr;

  const SetWrite({
    required this.id,
    required this.exerciseId,
    required this.setNumber,
    required this.weightKg,
    required this.reps,
    this.rawUntouched = const {},
    required this.rir,
    required this.isWarmup,
    this.isTopSet = false,
    this.isPr = false,
  });
}

/// Describes one session to be persisted at session finish.
class SessionWrite {
  final String id;
  final String dateIso;
  final String? dayTemplateId;
  final String? splitLabel;
  final int? durationMin;
  final List<SetWrite> sets;

  const SessionWrite({
    required this.id,
    required this.dateIso,
    this.dayTemplateId,
    this.splitLabel,
    this.durationMin,
    required this.sets,
  });
}

// ── Top set ───────────────────────────────────────────────────────────────────

/// Index into [sets] of the top set for ONE exercise: heaviest non-warmup set,
/// tie-break weight DESC, reps DESC, set_number ASC, id ASC (mirrors the server).
/// Returns -1 if there is no non-warmup set. weightKg is TEXT → compare numerically.
int topSetIndex(List<SetWrite> sets) {
  var best = -1;
  for (var i = 0; i < sets.length; i++) {
    final s = sets[i];
    if (s.isWarmup) {
      continue;
    }
    if (best == -1) {
      best = i;
      continue;
    }
    final b = sets[best];
    final sw = double.tryParse(s.weightKg?.toString() ?? '') ?? 0;
    final bw = double.tryParse(b.weightKg?.toString() ?? '') ?? 0;
    if (sw > bw ||
        (sw == bw && s.reps > b.reps) ||
        (sw == bw && s.reps == b.reps && s.setNumber < b.setNumber) ||
        (sw == bw &&
            s.reps == b.reps &&
            s.setNumber == b.setNumber &&
            s.id.compareTo(b.id) < 0)) {
      best = i;
    }
  }
  return best;
}

// ── persistSession / replaceSession ───────────────────────────────────────────

/// The session INSERT. The training day is bound through a subquery so a day
/// deleted locally (mid-workout, or while a finished workout was resumed)
/// becomes NULL instead of an id the server's day_templates foreign key would
/// reject — a rejected session PUT makes the server skip every set PUT of the
/// batch as an orphan, and the whole workout then vanishes on sync-down.
const _insertSessionSql =
    'INSERT INTO sessions (id, date, day_template_id, split_label, duration_min) '
    'SELECT ?, ?, (SELECT id FROM day_templates WHERE id = ?), ?, ?';

List<Object?> _sessionArgs(SessionWrite w) => [
  w.id,
  w.dateIso,
  w.dayTemplateId,
  w.splitLabel,
  w.durationMin,
];

Future<void> _insertSets(SqlExecutor executor, SessionWrite write) async {
  for (final s in write.sets) {
    await executor.execute(
      'INSERT INTO sets (id, session_id, exercise_id, set_number, weight_kg, reps, rir, is_warmup, is_top_set, is_pr) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        s.id,
        write.id,
        s.exerciseId,
        s.setNumber,
        s.weightKg, // TEXT — never cast here; the schema maps NUMERIC → text
        s.reps,
        s.isWarmup ? null : s.rir, // warm-up RIR → null
        s.isWarmup ? 1 : 0,
        s.isTopSet ? 1 : 0,
        s.isPr ? 1 : 0,
      ],
    );
  }
}

/// Writes [write] to the database via [executor]: one `sessions` INSERT + one
/// `sets` INSERT per set.
///
/// The server stamps `user_id`; `is_top_set`/`is_pr` are stamped client-side
/// (see [topSetIndex]) so offline-logged data is correct before sync.
///
/// **Atomicity:** always call this inside `db.writeTransaction` via
/// [PowerSyncTxExecutor]; that ensures the session row and all set rows commit
/// as one local transaction and are uploaded as one CRUD batch.
Future<void> persistSession(SqlExecutor executor, SessionWrite write) async {
  await executor.execute(_insertSessionSql, _sessionArgs(write));
  await _insertSets(executor, write);
}

/// Replaces an already-finished session in place — finishing a resumed
/// workout: same session id and date, a new set of sets.
///
/// The session row is UPDATEd, never deleted. Uploaded as a PATCH of
/// `split_label`/`duration_min` only, it cannot be rejected by the server;
/// a DELETE + re-INSERT would instead lose the whole, already-synced workout
/// whenever the re-insert PUT is rejected (for example, its training day was
/// deleted since). The guarded INSERT re-creates the row only if it vanished
/// (deleted by a sync during the resumed workout) and otherwise inserts
/// nothing and uploads nothing. The sets are DELETE + INSERT with the same
/// ids, which PowerSync uploads as DELETE then PUT; the server recomputes the
/// top-set and PR flags for both.
///
/// Same atomicity rule as [persistSession].
Future<void> replaceSession(SqlExecutor executor, SessionWrite write) async {
  await executor.execute(
    'UPDATE sessions SET split_label = ?, duration_min = ? WHERE id = ?',
    [write.splitLabel, write.durationMin, write.id],
  );
  await executor.execute(
    '$_insertSessionSql WHERE NOT EXISTS (SELECT 1 FROM sessions WHERE id = ?)',
    [..._sessionArgs(write), write.id],
  );
  await executor.execute('DELETE FROM sets WHERE session_id = ?', [write.id]);
  await _insertSets(executor, write);
}

/// SQLite workflow state and authored workout aggregate. This boundary is pure
/// Dart so process recovery exercises exactly the implementation used by Flutter.
class WorkoutRepository {
  const WorkoutRepository.local(this.db);
  final LocalDatabase db;
  static const activeKey = 'active';
  static const finishedKey = 'last';

  PreparedDomainAction prepareFinish({
    required SessionWrite write,
    required int baseRevision,
    required Map<String, int> setBases,
    required Map<String, Object?> recovery,
    required int draftRevision,
    required String draftId,
    String? operationId,
    List<OperationDependency> dependencies = const [],
  }) => prepareDomain(
    db,
    RecordKind.workout,
    baseRevision == 0
        ? LocalActionKind.workoutFinish
        : LocalActionKind.workoutReplace,
    write.id,
    baseRevision,
    {
      'session': {
        'date': write.dateIso,
        'original_day_id': write.dayTemplateId,
        'split_label': write.splitLabel,
        'duration_min': write.durationMin,
      },
      'sets': [
        for (final set in write.sets)
          {
            'id': set.id,
            'exercise_id': set.exerciseId,
            'set_number': set.setNumber,
            'weight_kg': set.weightKg,
            'reps': set.rawUntouched.containsKey('reps')
                ? set.rawUntouched['reps']
                : set.reps,
            'rir': set.rawUntouched.containsKey('rir')
                ? set.rawUntouched['rir']
                : set.rir,
            'is_warmup': set.rawUntouched.containsKey('is_warmup')
                ? set.rawUntouched['is_warmup']
                : set.isWarmup
                ? 1
                : 0,
            'legacy_local_top': set.isTopSet ? 1 : 0,
            'legacy_local_pr': set.isPr ? 1 : 0,
          },
      ],
      'set_bases': setBases,
      'recovery': recovery,
      'draft_revision': draftRevision,
      'draft_id': draftId,
    },
    operationId: operationId,
    dependencies: dependencies,
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
    tx.requireRef(a.target, kind: RecordKind.workout);
    final input = intent.input;
    final old = a.baseLocalRevision == 0
        ? null
        : await observedRecord(tx, a.target, a.baseLocalRevision);
    final state = await tx.localState(LocalStateKind.draft, activeKey);
    if (state == null ||
        state['status'] != 'active' ||
        state['revision'] != input['draft_revision']) {
      throw const StoreException('stale_local_state');
    }
    final draft =
        jsonDecode(utf8.decode((state['payload_bytes'] as List).cast<int>()))
            as Map;
    if (draft['draftId'] != input['draft_id']) {
      throw const StoreException('stale_local_state');
    }
    final session = <String, Object?>{
      if (old != null) ...projectionFields(old),
      ...Map<String, Object?>.from(input['session'] as Map),
    };
    final originalDay = old?['original_day_id'] ?? session['original_day_id'];
    session['original_day_id'] = originalDay;
    if (old != null) {
      session['date'] = old['date'];
    }
    final day = originalDay == null
        ? null
        : await tx.record(
            LocalRef(
              tx.profileId,
              RecordKind.trainingDay,
              originalDay as String,
            ),
          );
    session['day_template_id'] = day == null || day['deleted'] == 1
        ? null
        : originalDay;
    session['created_at'] = old?['created_at'] ?? intent.createdAt;
    session['finished_at'] = intent.createdAt;
    if (old != null) {
      session['notes'] = old['notes'];
    }
    final existing = await tx.getAll(
      'SELECT * FROM sets WHERE profile_id=? AND session_id=?',
      [tx.profileId, a.target.id],
    );
    final bases = Map<String, dynamic>.from(input['set_bases'] as Map);
    for (final row in existing) {
      if (bases[row['id']] != row['revision']) {
        throw const StoreException('revision_conflict');
      }
    }
    final sets = (input['sets'] as List)
        .map((x) => Map<String, dynamic>.from(x as Map))
        .toList();
    final ids = sets.map((x) => x['id']).toSet();
    if (ids.length != sets.length) {
      throw const StoreException('duplicate_identity');
    }
    final revision = await putDomain(
      tx,
      a.target,
      session,
      sourceRevisionId: old?['source_revision_id'] as String?,
    );
    for (final row in existing.where(
      (r) => !ids.contains(r['id']) && r['deleted'] == 0,
    )) {
      await putDomain(
        tx,
        LocalRef(tx.profileId, RecordKind.workoutSet, row['id'] as String),
        projectionFields(row),
        deleted: true,
        sourceRevisionId: row['source_revision_id'] as String?,
      );
    }
    for (var index = 0; index < sets.length; index++) {
      final values = sets[index];
      final id = values.remove('id') as String;
      final ref = LocalRef(tx.profileId, RecordKind.workoutSet, id);
      final previous = await tx.record(ref);
      if (previous != null &&
          (previous['session_id'] != a.target.id ||
              previous['deleted'] == 1 ||
              bases[id] != previous['revision'])) {
        throw const StoreException('revision_conflict');
      }
      final exercise = await tx.record(
        LocalRef(
          tx.profileId,
          RecordKind.exercise,
          values['exercise_id'] as String,
        ),
      );
      if (exercise == null || (exercise['deleted'] == 1 && previous == null)) {
        throw const StoreException('missing_reference');
      }
      values.addAll({
        'session_id': a.target.id,
        'set_number': index + 1,
        'is_top_set': previous == null ? 0 : previous['is_top_set'],
        'is_pr': previous == null ? 0 : previous['is_pr'],
        'created_at': previous?['created_at'] ?? intent.createdAt,
        'updated_at': intent.createdAt,
      });
      final top = values.remove('legacy_local_top');
      final pr = values.remove('legacy_local_pr');
      final setRevision = await putDomain(tx, ref, {
        if (previous != null) ...projectionFields(previous),
        ...values,
      }, sourceRevisionId: previous?['source_revision_id'] as String?);
      await writeCompatibleSet(
        tx,
        id,
        setRevision,
        top: top as int,
        pr: pr as int,
      );
    }
    await tx.putLocalState(
      LocalStateKind.draft,
      activeKey,
      localBytes({'draftId': input['draft_id']}),
      expectedRevision: state['revision'] as int,
      status: 'completed',
    );
    final previousRecovery = await tx.localState(
      LocalStateKind.finishedRecovery,
      finishedKey,
    );
    await tx.putLocalState(
      LocalStateKind.finishedRecovery,
      finishedKey,
      localBytes(input['recovery']),
      expectedRevision: previousRecovery?['revision'] as int? ?? 0,
    );
    final timer = await tx.localState(LocalStateKind.timer, activeKey);
    await tx.putLocalState(
      LocalStateKind.timer,
      activeKey,
      localBytes({
        'draftId': input['draft_id'],
        'restStart': null,
        'restTotal': 0,
      }),
      expectedRevision: timer?['revision'] as int? ?? 0,
      status: 'completed',
    );
    return {'id': a.target.id, 'revision': revision};
  }
}

Future<void> writeCompatibleSet(
  LocalTransaction tx,
  String id,
  int revision, {
  required int top,
  required int pr,
}) => tx.execute('INSERT INTO derived_results VALUES(?,?,?,?,?,?,?,?)', [
  tx.profileId,
  'workout-set:$id:$revision',
  'reps-compat/1',
  'legacy-local',
  localBytes({'id': id, 'revision': revision}),
  localBytes({'is_top_set': top, 'is_pr': pr}),
  localBytes({
    'rule': 'heaviest/weight-reps-order-id',
    'captured_flags': 'separate',
    'successor': 'unsupported',
  }),
  OperationInstant.now().text,
]);

/// An immutable local-state request; drafts/timers never become public actions.
final class PreparedWorkflowState {
  PreparedWorkflowState(
    LocalDatabase db,
    Map<String, Object?> draft,
    Map<String, Object?> timer,
    this.expectedRevision, {
    this.status = 'active',
  }) : token = db.token,
       bytes = List.unmodifiable(localBytes(draft)),
       timerBytes = List.unmodifiable(localBytes(timer));
  final StoreToken token;
  final int expectedRevision;
  final String status;
  final List<int> bytes, timerBytes;
}

Future<int> commitWorkflowState(
  LocalDatabase db,
  PreparedWorkflowState intent,
) => db.writeTransaction(
  (tx) => executeWorkflowStateInTransaction(tx, intent),
  expected: intent.token,
);
Future<int> executeWorkflowStateInTransaction(
  LocalTransaction tx,
  PreparedWorkflowState intent,
) async {
  if (tx.profileId != intent.token.profileId) {
    throw const StoreException('foreign_profile');
  }
  if (tx.token.generation != intent.token.generation) {
    throw const StoreException('stale_generation');
  }
  final previous = await tx.localState(
    LocalStateKind.draft,
    WorkoutRepository.activeKey,
  );
  final bytes = localBytes(jsonDecode(utf8.decode(intent.bytes)));
  final timerBytes = localBytes(jsonDecode(utf8.decode(intent.timerBytes)));
  // A failed forwarding COMMIT can be reconciled by exact frozen bytes.
  if (previous != null &&
      previous['revision'] == intent.expectedRevision + 1 &&
      previous['status'] == intent.status &&
      base64Encode((previous['payload_bytes'] as List).cast<int>()) ==
          base64Encode(bytes)) {
    final timer = await tx.localState(
      LocalStateKind.timer,
      WorkoutRepository.activeKey,
    );
    if (timer == null ||
        base64Encode((timer['payload_bytes'] as List).cast<int>()) !=
            base64Encode(timerBytes)) {
      throw const StoreException('workflow_state_mismatch');
    }
    return previous['revision'] as int;
  }
  final revision = await tx.putLocalState(
    LocalStateKind.draft,
    WorkoutRepository.activeKey,
    bytes,
    expectedRevision: intent.expectedRevision,
    status: intent.status,
  );
  final timer = await tx.localState(
    LocalStateKind.timer,
    WorkoutRepository.activeKey,
  );
  await tx.putLocalState(
    LocalStateKind.timer,
    WorkoutRepository.activeKey,
    timerBytes,
    expectedRevision: timer?['revision'] as int? ?? 0,
    status: intent.status,
  );
  return revision;
}

class UnsavedEditors {
  UnsavedEditors._();

  static final instance = UnsavedEditors._();

  final _open = <Object, ({String kind, bool Function() unsaved})>{};
  final _owed = <String, ({String kind, Future<void> Function() write})>{};

  /// Records that [write] (the latest value for [key]) has not landed yet.
  /// Replaces an older owed write for the same key.
  void owe(String key, String kind, Future<void> Function() write) =>
      _owed[key] = (kind: kind, write: write);

  /// [write] landed: [key] is no longer owed, unless a newer write for it
  /// was owed meanwhile.
  void paid(String key, Future<void> Function() write) {
    if (identical(_owed[key]?.write, write)) {
      _owed.remove(key);
    }
  }

  /// Whether a write for [key] is still owed.
  bool isOwed(String key) => _owed.containsKey(key);

  /// Retries every owed write once; one that fails again stays owed. A
  /// write superseded while an earlier retry was awaited (a newer edit of
  /// the same key landed or was owed meanwhile) is skipped, never replayed
  /// over the newer value.
  Future<void> retryOwed() async {
    for (final MapEntry(:key, :value) in _owed.entries.toList()) {
      if (!identical(_owed[key]?.write, value.write)) {
        continue;
      }
      try {
        await value.write();
        paid(key, value.write);
      } catch (_) {
        // Still owed; still blocks capture.
      }
    }
  }

  void resetForTesting() {
    _open.clear();
    _owed.clear();
  }

  Future<void> drainOrThrow() async {
    await retryOwed();
    if (unsaved().isNotEmpty) {
      throw const StoreException('unsaved_editor_input');
    }
  }

  /// Registers an open form of [kind]; pass the returned handle to
  /// [unregister] when it closes.
  Object register(String kind, bool Function() hasUnsavedInput) {
    final handle = Object();
    _open[handle] = (kind: kind, unsaved: hasUnsavedInput);
    return handle;
  }

  void unregister(Object handle) => _open.remove(handle);

  /// Kinds of the open forms holding unsaved input and of owed writes,
  /// sorted.
  List<String> unsaved() => ({
    for (final f in _open.values)
      if (f.unsaved()) f.kind,
    for (final o in _owed.values) o.kind,
  }).toList()..sort();
}
