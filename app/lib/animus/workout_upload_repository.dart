import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../domain/evidence.dart';
import '../domain/local_action.dart';
import '../store/local_store.dart';
import 'config.dart';
import 'contracts.dart';
import 'workout_send_models.dart';
import 'workout_translation.dart';

const _attachmentKey = 'animus.native-workout.attachment/1';
const _selectionPrefix = 'animus.native-workout.selection/1/';
const _uuid = Uuid();

Map<String, dynamic> _decode(Object? bytes) =>
    uploadMap(jsonDecode(utf8.decode((bytes as List).cast<int>())));
String _hash(Object? value) => sha256.convert(localBytes(value)).toString();
Never _block(AnimusWorkoutSendIssue reason) =>
    throw WorkoutUploadBlocked(reason);

/// An attachment contains identity and allocation evidence only, never tokens.
Map<String, dynamic> workoutBinding(
  String installation,
  StoreToken token,
  AnimusConfig config,
  AnimusIdentity identity,
) => {
  'format': 'alkion-native-workout-binding/1',
  'translation': animusWorkoutTranslation,
  'installation_id': installation,
  'profile_id': token.profileId,
  'generation': token.generation,
  'issuer': identity.issuer.toString(),
  'subject': identity.subject,
  'api_origin': config.apiOrigin.toString(),
  'client_id': config.clientId,
  'data_space_id': config.dataSpaceId,
};

final class FrozenWorkoutSelection {
  FrozenWorkoutSelection(this.data);
  final Map<String, dynamic> data;
  String get id => data['selection_id'] as String;
  String get sessionId => data['session_id'] as String;
  String get operationId => uploadMap(data['finish'])['operation_id'] as String;
  Map<String, dynamic> get binding => uploadMap(data['binding']);
  List<Map<String, dynamic>> get definitions =>
      (data['definitions'] as List).map(uploadMap).toList();
  AnimusWorkoutSelection summary({
    AnimusWorkoutSendStatus status = AnimusWorkoutSendStatus.ready,
    AnimusWorkoutSendIssue? issue,
    bool verified = false,
  }) => AnimusWorkoutSelection(
    sessionId: sessionId,
    selectionId: id,
    exerciseCount: definitions.length,
    setCount:
        (uploadMap(uploadMap(data['finish'])['input'])['sets'] as List).length,
    exerciseNames: List.unmodifiable(
      definitions.map((d) => uploadMap(d['fields'])['name'] as String),
    ),
    status: status,
    issue: issue,
    workoutLabel:
        uploadMap(
              uploadMap(uploadMap(data['finish'])['input'])['session'],
            )['split_label']
            as String? ??
        '',
    savedDay:
        uploadMap(
              uploadMap(uploadMap(data['finish'])['input'])['session'],
            )['date']
            as String? ??
        '',
    readBackVerified: verified,
  );
}

final class WorkoutUploadAttempt {
  WorkoutUploadAttempt(this.row);
  final Map<String, dynamic> row;
  String get operationId => row['operation_id'] as String;
  String get id => row['attempt_id'] as String;
  Uint8List get bytes =>
      Uint8List.fromList((row['request_bytes'] as List).cast<int>());
  Map<String, dynamic> get command => uploadMap(jsonDecode(utf8.decode(bytes)));
}

/// Existing callback-scoped transactions are the only persistence boundary.
/// Every reservation/attempt/outcome is backup-covered by the existing schema.
final class WorkoutUploadRepository {
  WorkoutUploadRepository(this.db, this.installationId);
  final LocalDatabase db;
  final String installationId;

  Future<void> gate(
    LocalRead tx,
    Map<String, dynamic> binding, {
    FrozenWorkoutSelection? selection,
  }) async {
    final p = await tx.get('SELECT * FROM profile_state WHERE singleton=1');
    if (p['installation_id'] != installationId ||
        p['profile_id'] != binding['profile_id'] ||
        p['generation'] != binding['generation'] ||
        p['write_state'] != 'writable') {
      _block(AnimusWorkoutSendIssue.differentScope);
    }
    final blocking = await tx.getOptional(
      "SELECT 1 FROM reviews r LEFT JOIN review_decisions d ON d.profile_id=r.profile_id AND d.review_id=r.review_id WHERE r.profile_id=? AND d.review_id IS NULL AND r.category IN ('restore_newer_work','queue_read_failed','queue_malformed','queue_uncertain_entries','uncertain_queue_entry') LIMIT 1",
      [tx.profileId],
    );
    if (blocking != null) _block(AnimusWorkoutSendIssue.recoveryBlocked);
    final attachment = await tx.localState(
      LocalStateKind.semanticSetting,
      _attachmentKey,
    );
    if (attachment != null &&
        _hash(_decode(attachment['payload_bytes'])['binding']) !=
            _hash(binding)) {
      _block(AnimusWorkoutSendIssue.differentScope);
    }
    if (selection != null) {
      if (_hash(selection.binding) != _hash(binding)) {
        _block(AnimusWorkoutSendIssue.differentScope);
      }
      // Changed/replaced/deleted/source-backed workouts must never be relabelled
      // as the original selected native finish. Definitions use frozen revisions.
      final w = await tx.record(
        LocalRef(tx.profileId, RecordKind.workout, selection.sessionId),
      );
      if (w == null ||
          w['revision'] != 1 ||
          w['deleted'] != 0 ||
          w['source_revision_id'] != null) {
        _block(AnimusWorkoutSendIssue.unsupportedWorkout);
      }
    }
  }

  Future<void> check(
    Map<String, dynamic> binding,
    FrozenWorkoutSelection selection,
  ) => db.readTransaction(
    (tx) => gate(tx, binding, selection: selection),
    expected: db.token,
  );

  Future<FrozenWorkoutSelection?> load(String sessionId) =>
      db.readTransaction((tx) async {
        final row = await tx.localState(
          LocalStateKind.semanticSetting,
          '$_selectionPrefix$sessionId',
        );
        if (row == null) return null;
        final data = _decode(row['payload_bytes']);
        if (data['format'] != 'alkion-native-workout-selection/1' ||
            data['translation'] != animusWorkoutTranslation) {
          _block(AnimusWorkoutSendIssue.differentScope);
        }
        return FrozenWorkoutSelection(data);
      });

  Future<FrozenWorkoutSelection> select(
    String sessionId,
    Map<String, dynamic> binding,
    void Function() current,
  ) => db.writeTransaction((tx) async {
    current();
    await gate(tx, binding);
    current();
    final old = await tx.localState(
      LocalStateKind.semanticSetting,
      '$_selectionPrefix$sessionId',
    );
    if (old != null) {
      final selected = FrozenWorkoutSelection(_decode(old['payload_bytes']));
      await gate(tx, binding, selection: selected);
      current();
      return selected;
    }
    final workout = await tx.record(
      LocalRef(tx.profileId, RecordKind.workout, sessionId),
    );
    if (workout == null ||
        workout['revision'] != 1 ||
        workout['deleted'] != 0 ||
        workout['source_revision_id'] != null) {
      _block(AnimusWorkoutSendIssue.unsupportedWorkout);
    }
    final revisions = await tx.getAll(
      'SELECT * FROM record_revisions WHERE profile_id=? AND kind=? AND record_id=? ORDER BY revision',
      [tx.profileId, 'workout', sessionId],
    );
    if (revisions.length != 1 ||
        revisions.single['layer'] != 'authored' ||
        revisions.single['source_revision_id'] != null) {
      _block(AnimusWorkoutSendIssue.unsupportedWorkout);
    }
    final finishRow = await tx.getOptional(
      'SELECT * FROM operations WHERE profile_id=? AND family=? AND operation_id=?',
      [tx.profileId, 'workouts', revisions.single['operation_id']],
    );
    if (finishRow == null ||
        finishRow['action'] != 'workoutFinish' ||
        finishRow['base_local_revision'] != 0) {
      _block(AnimusWorkoutSendIssue.unsupportedWorkout);
    }
    final finish = _nativeAction(finishRow, tx.profileId);
    final input = uploadMap(finish['input']);
    final session = uploadMap(input['session']);
    _checkWorkoutMetadata(session);
    final time = input['finish_time_evidence'];
    if (time is! Map || !_validTime(uploadMap(time), session['date'])) {
      _block(AnimusWorkoutSendIssue.missingTimeEvidence);
    }
    final sets = (input['sets'] as List).map(uploadMap).toList();
    if (sets.isEmpty || sets.length > 1000) {
      _block(AnimusWorkoutSendIssue.invalidValues);
    }
    final actualSets = await tx.getAll(
      'SELECT id,revision,deleted,source_revision_id FROM sets WHERE profile_id=? AND session_id=?',
      [tx.profileId, sessionId],
    );
    if (actualSets.length != sets.length ||
        actualSets.any(
          (s) =>
              s['revision'] != 1 ||
              s['deleted'] != 0 ||
              s['source_revision_id'] != null,
        )) {
      _block(AnimusWorkoutSendIssue.unsupportedWorkout);
    }
    final exerciseIds = <String>[];
    var previous = '', expectedNumber = 1;
    var seenWorking = false, anyWorking = false;
    for (final set in sets) {
      final id = set['exercise_id'];
      if (id is! String ||
          set['set_number'] != expectedNumber++ ||
          !isCanonicalAnimusUuid(set['id'] as String? ?? '') ||
          set['reps'] is! int ||
          (set['reps'] as int) < 0 ||
          (set['rir'] != null &&
              (set['rir'] is! int ||
                  (set['rir'] as int) < 0 ||
                  (set['rir'] as int) > 5)) ||
          (set['is_warmup'] != 0 && set['is_warmup'] != 1) ||
          (set['weight_kg'] != null &&
              (set['weight_kg'] is! String ||
                  !RegExp(
                    r'^-?(?:0|[1-9]\d*)(?:\.\d+)?$',
                  ).hasMatch(set['weight_kg'] as String)))) {
        _block(AnimusWorkoutSendIssue.invalidValues);
      }
      if (previous != id) {
        if (exerciseIds.contains(id)) {
          _block(AnimusWorkoutSendIssue.invalidValues);
        }
        exerciseIds.add(id);
        previous = id;
        seenWorking = false;
      }
      if (set['is_warmup'] == 1 && (seenWorking || set['rir'] != null)) {
        _block(AnimusWorkoutSendIssue.invalidValues);
      }
      if (set['is_warmup'] == 0) {
        seenWorking = true;
        anyWorking = true;
      }
    }
    if (!anyWorking || exerciseIds.length > 100) {
      _block(AnimusWorkoutSendIssue.invalidValues);
    }
    final attachmentRow = await tx.localState(
      LocalStateKind.semanticSetting,
      _attachmentKey,
    );
    final attachment = attachmentRow == null
        ? <String, dynamic>{
            'format': 'alkion-native-workout-attachment/1',
            'binding': binding,
            'exercises': <String, dynamic>{},
          }
        : _decode(attachmentRow['payload_bytes']);
    final allocations = uploadMap(attachment['exercises']);
    final definitions = <Map<String, dynamic>>[];
    for (final id in exerciseIds) {
      final row = await tx.record(
        LocalRef(tx.profileId, RecordKind.exercise, id),
      );
      if (row == null ||
          row['deleted'] != 0 ||
          row['source_revision_id'] != null ||
          row['is_template'] != 0) {
        _block(AnimusWorkoutSendIssue.unsupportedDefinition);
      }
      final history = await tx.getAll(
        'SELECT * FROM record_revisions WHERE profile_id=? AND kind=? AND record_id=? ORDER BY revision',
        [tx.profileId, 'exercise', id],
      );
      final chain = <Map<String, dynamic>>[];
      var base = 0;
      for (final revision in history) {
        if (revision['revision'] != base + 1 ||
            revision['layer'] != 'authored' ||
            revision['source_revision_id'] != null ||
            revision['deleted'] != 0) {
          _block(AnimusWorkoutSendIssue.unsupportedDefinition);
        }
        final op = await tx.get(
          'SELECT * FROM operations WHERE profile_id=? AND family=? AND operation_id=?',
          [tx.profileId, 'workouts', revision['operation_id']],
        );
        if (op['action'] !=
                (base == 0 ? 'definitionCreate' : 'definitionEdit') ||
            op['target_id'] != id ||
            op['base_local_revision'] != base) {
          _block(AnimusWorkoutSendIssue.unsupportedDefinition);
        }
        final action = _nativeAction(op, tx.profileId);
        final patch = uploadMap(action['input']);
        // Batch/template/absorption and source-copy actions need a separate
        // reviewed translation. This slice admits native field actions only.
        if (patch.keys.any((k) => k != 'fields')) {
          _block(AnimusWorkoutSendIssue.unsupportedDefinition);
        }
        try {
          nativeDefinitionPatch(uploadMap(patch['fields']), create: base == 0);
        } on FormatException {
          _block(AnimusWorkoutSendIssue.invalidValues);
        }
        chain.add({'revision': revision['revision'], 'action': action});
        base++;
      }
      if (base != row['revision'] || chain.isEmpty) {
        _block(AnimusWorkoutSendIssue.unsupportedDefinition);
      }
      allocations[id] ??= _uuid.v4();
      definitions.add({
        'local_id': id,
        'target_id': allocations[id],
        'revision': base,
        'fields': _decode(history.last['payload_bytes']),
        'chain': chain,
      });
    }
    final selected = FrozenWorkoutSelection({
      'format': 'alkion-native-workout-selection/1',
      'translation': animusWorkoutTranslation,
      'selection_id': _uuid.v4(),
      'session_id': sessionId,
      'target_id': _uuid.v4(),
      'binding': binding,
      'finish': finish,
      'definitions': definitions,
      'block_ids': {for (final id in exerciseIds) id: _uuid.v4()},
      'set_ids': {for (final set in sets) set['id'] as String: _uuid.v4()},
    });
    attachment['exercises'] = allocations;
    await tx.putLocalState(
      LocalStateKind.semanticSetting,
      _attachmentKey,
      localBytes(attachment),
      expectedRevision: attachmentRow?['revision'] as int? ?? 0,
    );
    await tx.putLocalState(
      LocalStateKind.semanticSetting,
      '$_selectionPrefix$sessionId',
      localBytes(selected.data),
      expectedRevision: 0,
    );
    current();
    return selected;
  }, expected: db.token);

  Map<String, dynamic> _nativeAction(Map<String, dynamic> row, String profile) {
    final action = _decode(row['input_bytes']);
    if (action['format'] != 'alkion-local-action/1' ||
        action['semantic_version'] != 1 ||
        action['origin'] != null ||
        action['eligibility'] != 'awaitingAttachment' ||
        uploadMap(action['target'])['profile_id'] != profile ||
        !isCanonicalAnimusUuid(action['operation_id'] as String? ?? '') ||
        sha256.convert((row['input_bytes'] as List).cast<int>()).toString() !=
            row['input_hash']) {
      _block(AnimusWorkoutSendIssue.unsupportedDefinition);
    }
    return action;
  }

  Future<WorkoutUploadAttempt?> attempt(
    String operationId,
  ) => db.readTransaction((tx) async {
    final rows = await tx.getAll(
      'SELECT * FROM operation_attempts WHERE profile_id=? AND family=? AND operation_id=? ORDER BY attempted_at,attempt_id',
      [tx.profileId, 'workouts', operationId],
    );
    if (rows.length > 1) _block(AnimusWorkoutSendIssue.differentScope);
    return rows.isEmpty ? null : WorkoutUploadAttempt(rows.single);
  });

  Future<WorkoutUploadAttempt> freezeAttempt(
    FrozenWorkoutSelection selection,
    Map<String, dynamic> binding,
    Map<String, dynamic> command,
    void Function() current,
  ) async {
    final encoded = AnimusCommandBytes(command);
    if (!encoded.withinBudget) _block(AnimusWorkoutSendIssue.requestTooLarge);
    return db.writeTransaction((tx) async {
      current();
      await gate(tx, binding, selection: selection);
      current();
      final op = command['operation_id'] as String;
      final existing = await tx.getAll(
        'SELECT * FROM operation_attempts WHERE profile_id=? AND family=? AND operation_id=?',
        [tx.profileId, 'workouts', op],
      );
      if (existing.isNotEmpty) {
        final row = existing.single;
        if (_hash(_decode(row['binding_bytes'])) != _hash(binding) ||
            row['translation_version'] != animusWorkoutTranslation ||
            row['request_hash'] != encoded.wireHash) {
          _block(AnimusWorkoutSendIssue.differentScope);
        }
        return WorkoutUploadAttempt(row);
      }
      final id = _uuid.v4(), now = OperationInstant.now().text;
      final row = <String, dynamic>{
        'operation_id': op,
        'attempt_id': id,
        'request_bytes': encoded.wire,
        'request_hash': encoded.wireHash,
        'translation_version': animusWorkoutTranslation,
        'binding_bytes': localBytes(binding),
        'server_base_revision': '${command['base_revision']}',
        'attempted_at': now,
      };
      await tx.execute(
        'INSERT INTO operation_attempts VALUES(?,?,?,?,?,?,?,?,?,?)',
        [
          tx.profileId,
          'workouts',
          op,
          id,
          animusWorkoutTranslation,
          encoded.wire,
          encoded.wireHash,
          localBytes(binding),
          row['server_base_revision'],
          now,
        ],
      );
      current();
      return WorkoutUploadAttempt(row);
    }, expected: db.token);
  }

  Future<Map<String, dynamic>?> acknowledged(
    WorkoutUploadAttempt attempt,
  ) => db.readTransaction((tx) async {
    final rows = await tx.getAll(
      'SELECT outcome_bytes FROM attempt_outcomes WHERE profile_id=? AND family=? AND operation_id=? AND attempt_id=? ORDER BY received_at,outcome_id',
      [tx.profileId, 'workouts', attempt.operationId, attempt.id],
    );
    for (final row in rows.reversed) {
      final out = _decode(row['outcome_bytes']);
      if (out['kind'] == 'acknowledged') return out;
    }
    return null;
  });

  Future<void> outcome(
    FrozenWorkoutSelection selection,
    Map<String, dynamic> binding,
    WorkoutUploadAttempt attempt,
    Map<String, dynamic> evidence,
    void Function() current,
  ) => db.writeTransaction((tx) async {
    current();
    await gate(tx, binding, selection: selection);
    current();
    if (_hash(_decode(attempt.row['binding_bytes'])) != _hash(binding) ||
        sha256.convert(attempt.bytes).toString() !=
            attempt.row['request_hash']) {
      _block(AnimusWorkoutSendIssue.differentScope);
    }
    final id = _uuid.v4();
    String? review;
    if (evidence['kind'] != 'acknowledged' && evidence['kind'] != 'read_back') {
      review = 'animus-upload-$id';
      await tx.addReview(
        id: review,
        category: 'animus_workout_upload',
        evidence: localBytes({
          'attempt_id': attempt.id,
          'operation_id': attempt.operationId,
          ...evidence,
        }),
      );
    }
    await tx.execute('INSERT INTO attempt_outcomes VALUES(?,?,?,?,?,?,?,?)', [
      tx.profileId,
      'workouts',
      attempt.operationId,
      attempt.id,
      id,
      localBytes({'format': 'alkion-native-workout-outcome/1', ...evidence}),
      review,
      OperationInstant.now().text,
    ]);
    current();
  }, expected: db.token);

  Future<AnimusWorkoutSelection> summary(
    FrozenWorkoutSelection selection,
  ) async {
    var a = await attempt(selection.operationId);
    if (a == null) {
      for (final definition in selection.definitions) {
        for (final raw in definition['chain'] as List) {
          final op =
              uploadMap(uploadMap(raw)['action'])['operation_id'] as String;
          final dependency = await attempt(op);
          if (dependency != null && await acknowledged(dependency) == null) {
            a = dependency;
            break;
          }
        }
        if (a != null) break;
      }
      if (a == null) return selection.summary();
    }
    final ack = await acknowledged(a);
    final outcomes = await db.getAll(
      'SELECT outcome_bytes FROM attempt_outcomes WHERE profile_id=? AND family=? AND operation_id=? AND attempt_id=? ORDER BY received_at,outcome_id',
      [db.profileId, 'workouts', a.operationId, a.id],
    );
    final decoded = outcomes.map((r) => _decode(r['outcome_bytes'])).toList();
    if (ack != null) {
      return selection.summary(
        status: AnimusWorkoutSendStatus.sent,
        verified: decoded.any((o) => o['kind'] == 'read_back'),
        issue: decoded.any((o) => o['kind'] == 'read_back')
            ? null
            : AnimusWorkoutSendIssue.readBackFailed,
      );
    }
    final last = decoded.isEmpty ? null : decoded.last;
    final issue =
        last?['kind'] == 'rejected' &&
            last?['http_status'] == 400 &&
            a.command['workout'] != null
        ? AnimusWorkoutSendIssue.invalidValues
        : last == null
        ? null
        : AnimusWorkoutSendIssue.values
              .where((v) => v.name == last['issue'])
              .firstOrNull;
    return selection.summary(
      status: last?['kind'] == 'rejected'
          ? AnimusWorkoutSendStatus.needsReview
          : AnimusWorkoutSendStatus.uncertain,
      issue: issue,
    );
  }
}

void _checkWorkoutMetadata(Map<String, dynamic> session) {
  try {
    nativeWorkoutMetadata(session);
  } on FormatException {
    _block(AnimusWorkoutSendIssue.invalidValues);
  }
}

bool _validTime(Map<String, dynamic> t, Object? day) {
  if (t['format'] != 'alkion-native-finish-time/1' ||
      t['finished_at'] is! String ||
      t['offset_minutes'] is! int ||
      t['timezone'] is! String ||
      (t['timezone'] as String).isEmpty ||
      t['elapsed_seconds'] is! int ||
      (t['elapsed_seconds'] as int) < 0) {
    return false;
  }
  final instant = t['finished_at'] as String;
  final match = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(Z|([+-])(\d{2}):(\d{2}))$',
  ).firstMatch(instant);
  if (match == null) return false;
  final offset = match[1] == 'Z'
      ? 0
      : (int.parse(match[3]!) * 60 + int.parse(match[4]!)) *
            (match[2] == '-' ? -1 : 1);
  try {
    OperationInstant(instant);
    CalendarDay(instant.substring(0, 10));
    return offset == t['offset_minutes'] &&
        day == instant.substring(0, 10) &&
        (match[1] == 'Z' || int.parse(match[4]!) < 60) &&
        offset.abs() < 24 * 60;
  } on FormatException {
    return false;
  }
}
