import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../domain/evidence.dart';
import '../identity/alkion_identity.dart';
import '../recovery/backup.dart' show RecoveryCheckpoint, canonicalValue;
import '../session/active_session_controller.dart';
import '../store/local_store.dart';
import 'finished_session_store.dart';

/// Review category of workflow state this build could not read at launch.
const workflowQuarantineCategory = 'workflow_state_unreadable';
const workflowQuarantineFormat = 'alkion-workflow-quarantine/1';
const workflowQuarantineDecisionFormat =
    'alkion-workflow-quarantine-decision/1';
const workflowNoticeDecision = 'notice';

const _draftFormats = ['alkion-session-draft/2', 'unversioned-legacy'];
const _finishedFormats = [
  'finished-session/unversioned',
  'alkion-session-draft/2',
  'unversioned-legacy',
];
const _activeKey = 'active';
const _finishedKey = 'last';

/// Why one stored value could not be read. [reason] is the quarantine
/// reason; [loaderCategory] is what the in-runtime loaders throw for it.
final class WorkflowStateDamage {
  const WorkflowStateDamage(
    this.reason,
    this.failedStep,
    this.errorType,
    this.errorMessage,
  );
  final String reason, failedStep, errorType, errorMessage;

  String get loaderCategory => switch (reason) {
    'draft_unreadable' ||
    'draft_unsupported_format' => 'malformed_draft_preserved',
    'finished_recovery_unreadable' ||
    'finished_recovery_unsupported_format' => 'malformed_recovery_preserved',
    'timer_evidence_unreadable' => 'malformed_timer_preserved',
    _ => reason,
  };
}

/// Exactly one of [value] and [damage] is set.
final class WorkflowStateRead<T extends Object> {
  const WorkflowStateRead.readable(T this.value) : damage = null;
  const WorkflowStateRead.damaged(WorkflowStateDamage this.damage)
    : value = null;
  final T? value;
  final WorkflowStateDamage? damage;
}

String _sqlType(Object? value) => switch (value) {
  null => 'NULL',
  String() => 'TEXT',
  int() => 'INTEGER',
  double() => 'REAL',
  _ => value.runtimeType.toString(),
};

/// The first 512 characters (code points) of an error, so a surrogate pair
/// is never split.
@visibleForTesting
String workflowErrorMessage(Object error) {
  final text = '$error';
  return text.runes.length <= 512
      ? text
      : String.fromCharCodes(text.runes.take(512));
}

String _message(Object error) => workflowErrorMessage(error);

/// Steps 1–3 of every classifier: a BLOB holding UTF-8 JSON. Only values
/// already read are inspected here, so no storage failure is ever classified.
Object? _decodeJson(
  Object? payload,
  String reason,
  String prefix,
  void Function(WorkflowStateDamage) fail,
) {
  if (payload is! List) {
    fail(
      WorkflowStateDamage(
        reason,
        '${prefix}blob',
        'payload_type',
        'payload_bytes is ${_sqlType(payload)}',
      ),
    );
    return null;
  }
  final String text;
  try {
    text = utf8.decode(payload.cast<int>());
  } catch (error) {
    fail(
      WorkflowStateDamage(
        reason,
        '${prefix}utf8',
        error.runtimeType.toString(),
        _message(error),
      ),
    );
    return null;
  }
  try {
    return jsonDecode(text);
  } catch (error) {
    fail(
      WorkflowStateDamage(
        reason,
        '${prefix}json',
        error.runtimeType.toString(),
        _message(error),
      ),
    );
    return null;
  }
}

bool _unsupportedDraftFormat(Object? json) =>
    json is Map &&
    (json.containsKey('format') || json.containsKey('version')) &&
    (json['format'] != 'alkion-session-draft' || json['version'] != 2);

/// The single readability rule for a stored `draft/active` payload.
WorkflowStateRead<SessionDraft> classifyDraftPayload(Object? payload) {
  WorkflowStateDamage? damage;
  final json = _decodeJson(payload, 'draft_unreadable', '', (d) => damage = d);
  if (damage != null) return WorkflowStateRead.damaged(damage!);
  try {
    return WorkflowStateRead.readable(
      SessionDraft.fromJson(json as Map<String, dynamic>),
    );
  } catch (error) {
    final format = _unsupportedDraftFormat(json);
    return WorkflowStateRead.damaged(
      WorkflowStateDamage(
        format ? 'draft_unsupported_format' : 'draft_unreadable',
        format ? 'format' : 'shape',
        error.runtimeType.toString(),
        _message(error),
      ),
    );
  }
}

/// The timer evidence a readable draft needs, or why it is unusable.
WorkflowStateDamage? classifyTimerRow(
  Map<String, dynamic>? timer,
  String draftId,
) {
  if (timer == null) {
    return const WorkflowStateDamage(
      'timer_evidence_unavailable',
      'timer_missing',
      'missing_row',
      'timer/active is absent',
    );
  }
  if (timer['status'] != 'active') {
    return WorkflowStateDamage(
      'timer_evidence_unavailable',
      'timer_inactive',
      'inactive_row',
      'timer/active status is ${timer['status']}',
    );
  }
  WorkflowStateDamage? damage;
  final json = _decodeJson(
    timer['payload_bytes'],
    'timer_evidence_unreadable',
    'timer_',
    (d) => damage = d,
  );
  if (damage != null) return damage;
  if (json is! Map) {
    return WorkflowStateDamage(
      'timer_evidence_unreadable',
      'timer_shape',
      'payload_shape',
      'timer payload is ${json.runtimeType}, not a JSON object',
    );
  }
  if (json['draftId'] != draftId) {
    return const WorkflowStateDamage(
      'timer_draft_mismatch',
      'timer_draft',
      'draft_mismatch',
      'timer draftId differs from the draft',
    );
  }
  return null;
}

/// The single readability rule for a stored `finishedRecovery/last` payload.
WorkflowStateRead<FinishedSession> classifyFinishedPayload(Object? payload) {
  WorkflowStateDamage? damage;
  final json = _decodeJson(
    payload,
    'finished_recovery_unreadable',
    '',
    (d) => damage = d,
  );
  if (damage != null) return WorkflowStateRead.damaged(damage!);
  try {
    return WorkflowStateRead.readable(
      FinishedSession.fromJson(json as Map<String, dynamic>),
    );
  } catch (error) {
    final format = json is Map && _unsupportedDraftFormat(json['draft']);
    return WorkflowStateRead.damaged(
      WorkflowStateDamage(
        format
            ? 'finished_recovery_unsupported_format'
            : 'finished_recovery_unreadable',
        format ? 'format' : 'shape',
        error.runtimeType.toString(),
        _message(error),
      ),
    );
  }
}

/// The running build, recorded with each review. Quarantine never fails for
/// lack of a version: an unknown one is recorded as `unknown`.
final class DecoderInfo {
  DecoderInfo({
    this.appVersion = 'unknown',
    this.buildNumber = 'unknown',
    String? flavor,
  }) : flavor = flavor ?? AlkionIdentity.current.name;
  final String appVersion, buildNumber, flavor;
}

final class _DamagedGroup {
  _DamagedGroup(this.kind, this.rows, this.damage);
  final LocalStateKind kind;
  final List<Map<String, dynamic>> rows;
  final WorkflowStateDamage damage;

  Map<String, Object?> get core => {
    'format': workflowQuarantineFormat,
    'kind': kind.name,
    'rows': [
      for (final row in rows)
        {
          for (final entry in row.entries)
            entry.key: canonicalValue(entry.value),
        },
    ],
  };
}

Future<List<_DamagedGroup>> _inspect(LocalRead tx) async {
  final groups = <_DamagedGroup>[];
  final draft = await tx.localState(LocalStateKind.draft, _activeKey);
  if (draft != null && draft['status'] == 'active') {
    final timer = await tx.localState(LocalStateKind.timer, _activeKey);
    final read = classifyDraftPayload(draft['payload_bytes']);
    final damage = read.damage ?? classifyTimerRow(timer, read.value!.draftId);
    if (damage != null) {
      groups.add(_DamagedGroup(LocalStateKind.draft, [draft, ?timer], damage));
    }
  }
  final finished = await tx.localState(
    LocalStateKind.finishedRecovery,
    _finishedKey,
  );
  if (finished != null && finished['status'] == 'active') {
    final damage = classifyFinishedPayload(finished['payload_bytes']).damage;
    if (damage != null) {
      groups.add(
        _DamagedGroup(LocalStateKind.finishedRecovery, [finished], damage),
      );
    }
  }
  return groups;
}

String _id(List<int> bytes) =>
    'wq-${sha256.convert(bytes).toString().substring(0, 40)}';

/// Whether an existing review holds exactly this group's `{format, kind,
/// rows}`. The decoder record never takes part in identity.
bool _sameCore(Map<String, dynamic> review, List<int> core) {
  if (review['category'] != workflowQuarantineCategory) return false;
  final Object? evidence;
  try {
    evidence = jsonDecode(
      utf8.decode((review['evidence_bytes'] as List).cast<int>()),
    );
  } catch (_) {
    return false;
  }
  if (evidence is! Map) return false;
  final List<int> existing;
  try {
    existing = localBytes({
      'format': evidence['format'],
      'kind': evidence['kind'],
      'rows': evidence['rows'],
    });
  } catch (_) {
    return false;
  }
  return base64Encode(existing) == base64Encode(core);
}

Future<String> _keep(
  LocalTransaction tx,
  _DamagedGroup group,
  DecoderInfo decoder,
) async {
  final coreValue = group.core;
  final core = localBytes(coreValue);
  Future<Map<String, dynamic>?> review(String id) => tx.getOptional(
    'SELECT category,evidence_bytes FROM reviews WHERE profile_id=? AND review_id=?',
    [tx.profileId, id],
  );
  Future<void> insert(String id, {String? conflictsWith}) => tx.addReview(
    id: id,
    category: workflowQuarantineCategory,
    evidence: localBytes({
      ...coreValue,
      'reason': group.damage.reason,
      'decoder': {
        'app_version': decoder.appVersion,
        'build_number': decoder.buildNumber,
        'flavor': decoder.flavor,
        'supported_formats': group.kind == LocalStateKind.draft
            ? _draftFormats
            : _finishedFormats,
        'failed_step': group.damage.failedStep,
        'error_type': group.damage.errorType,
        'error_message': group.damage.errorMessage,
      },
      'conflicts_with': ?conflictsWith,
    }),
  );

  final id = _id(core);
  final existing = await review(id);
  if (existing == null) {
    await insert(id);
    return id;
  }
  if (_sameCore(existing, core)) return id;
  // A prefix collision or a tampered review: keep both, never choose.
  final fallback = _id([...utf8.encode('conflict:$id'), ...core]);
  final taken = await review(fallback);
  if (taken == null) {
    await insert(fallback, conflictsWith: id);
    return fallback;
  }
  if (_sameCore(taken, core)) return fallback;
  throw const StoreException('quarantine_conflict_preserved');
}

/// Copies unreadable active workflow state into `reviews` and retires it, in
/// one transaction, before any controller owns the rows. A read transaction
/// decides first; nothing is written unless it found damage. Storage failures
/// propagate unchanged. Returns the review IDs that hold the damaged groups.
/// [decoder] is called only once damage is found, before the write
/// transaction, so a clean launch never asks the platform for a version;
/// without it the build is recorded as `unknown`.
Future<List<String>> quarantineUnreadableWorkflowState(
  LocalDatabase db, {
  Future<DecoderInfo> Function()? decoder,
  @visibleForTesting RecoveryCheckpoint? checkpoint,
}) async {
  final expected = db.token;
  final damaged = await db.readTransaction(
    (tx) async => (await _inspect(tx)).isNotEmpty,
    expected: expected,
  );
  if (!damaged) return const [];
  final info = decoder == null ? DecoderInfo() : await decoder();
  final ids = await db.writeTransaction((tx) async {
    final groups = await _inspect(tx);
    final ids = [for (final group in groups) await _keep(tx, group, info)];
    await checkpoint?.call('quarantine-review-written');
    for (final group in groups) {
      for (final row in group.rows) {
        if (row['status'] != 'active') continue;
        await tx.retireLocalState(
          LocalStateKind.values.byName(row['state_kind'] as String),
          row['state_key'] as String,
          expectedRevision: row['revision'] as int,
        );
      }
    }
    return ids;
  }, expected: expected);
  await checkpoint?.call('quarantine-committed');
  return ids;
}

enum KeptWorkflowKind { draft, finishedRecovery, unknown }

/// One kept quarantine review, as the notice and the Backup screen show it.
final class KeptWorkflowState {
  const KeptWorkflowState(this.reviewId, this.kind, this.createdAt);
  final String reviewId;
  final KeptWorkflowKind kind;

  /// The review's stored `created_at` operation instant.
  final String createdAt;
}

/// Read and acknowledge kept workflow state. The `notice` decision only
/// records that the notice was seen; it decides nothing about the evidence.
final class WorkflowStateQuarantine {
  const WorkflowStateQuarantine(this.db);
  final LocalDatabase db;

  Future<List<KeptWorkflowState>> keptReviews() => _list(pendingOnly: false);

  /// Kept reviews whose notice has not been acknowledged yet.
  Future<List<KeptWorkflowState>> pendingNotices() => _list(pendingOnly: true);

  Future<List<KeptWorkflowState>> _list({
    required bool pendingOnly,
  }) => db.readTransaction((tx) async {
    final rows = await tx.getAll(
      'SELECT r.review_id,r.evidence_bytes,r.created_at FROM reviews r WHERE r.profile_id=? AND r.category=?'
      '${pendingOnly ? ' AND NOT EXISTS (SELECT 1 FROM review_decisions d WHERE d.profile_id=r.profile_id AND d.review_id=r.review_id AND d.decision_id=?)' : ''}'
      ' ORDER BY r.created_at,r.review_id',
      [
        tx.profileId,
        workflowQuarantineCategory,
        if (pendingOnly) workflowNoticeDecision,
      ],
    );
    return [
      for (final row in rows)
        KeptWorkflowState(
          row['review_id'] as String,
          _kind(row['evidence_bytes']),
          row['created_at'] as String,
        ),
    ];
  }, expected: db.token);

  static KeptWorkflowKind _kind(Object? bytes) {
    try {
      final evidence = jsonDecode(utf8.decode((bytes as List).cast<int>()));
      return switch (evidence is Map ? evidence['kind'] : null) {
        'draft' => KeptWorkflowKind.draft,
        'finishedRecovery' => KeptWorkflowKind.finishedRecovery,
        _ => KeptWorkflowKind.unknown,
      };
    } catch (_) {
      return KeptWorkflowKind.unknown;
    }
  }

  /// Records one `notice` decision per shown review, in one transaction.
  /// Existing decisions and IDs that are not kept workflow reviews are skipped.
  Future<void> acknowledge(Iterable<String> reviewIds) {
    final ids = reviewIds.toSet();
    if (ids.isEmpty) return Future.value();
    return db.writeTransaction((tx) async {
      for (final id in ids) {
        final pending = await tx.getOptional(
          'SELECT 1 FROM reviews r WHERE r.profile_id=? AND r.review_id=? AND r.category=? AND NOT EXISTS (SELECT 1 FROM review_decisions d WHERE d.profile_id=r.profile_id AND d.review_id=r.review_id AND d.decision_id=?)',
          [
            tx.profileId,
            id,
            workflowQuarantineCategory,
            workflowNoticeDecision,
          ],
        );
        if (pending == null) continue;
        await tx.execute('INSERT INTO review_decisions VALUES(?,?,?,?,?)', [
          tx.profileId,
          id,
          workflowNoticeDecision,
          localBytes({
            'format': workflowQuarantineDecisionFormat,
            'decision': 'notice_acknowledged',
          }),
          OperationInstant.now().text,
        ]);
      }
    }, expected: db.token);
  }
}
