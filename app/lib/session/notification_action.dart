import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../domain/evidence.dart';
import '../identity/alkion_identity.dart';
import '../store/local_store.dart';
import 'notification_envelope.dart';

export 'notification_envelope.dart'
    show NotificationAction, NotificationIntent, NotificationIntentKind;

const notificationActionKey = 'notification-action';

/// Whether [action] was issued for this store generation's profile and the
/// current draft.
bool ownsNotificationAction(
  NotificationAction action,
  LocalDatabase db,
  String currentDraft,
) =>
    action.applicationId == AlkionIdentity.applicationId &&
    action.profileId == db.profileId &&
    action.generation == db.token.generation &&
    action.draftId == currentDraft;

Map<String, Object?> _payload(Map<String, dynamic> row) =>
    Map<String, Object?>.from(
      jsonDecode(utf8.decode((row['payload_bytes'] as List).cast<int>()))
          as Map,
    );

/// The rest a token is judged by: the SQL `draftId`, `restStart` and
/// `restTotal`, compared as the exact stored JSON values. Timer revisions play
/// no part (spec D5): every draft save rewrites the timer row.
final class _Rest {
  const _Rest(this.draftId, this.restStart, this.restTotal);
  final String draftId;
  final String? restStart;
  final int restTotal;

  Map<String, Object?> toJson() => {
    'draft_id': draftId,
    'rest_start': restStart,
    'rest_total': restTotal,
  };

  static _Rest? fromJson(Object? json) {
    if (json is! Map || json.length != 3) return null;
    final draftId = json['draft_id'],
        restStart = json['rest_start'],
        restTotal = json['rest_total'];
    if (draftId is! String ||
        (restStart != null && restStart is! String) ||
        restTotal is! int) {
      return null;
    }
    return _Rest(draftId, restStart as String?, restTotal);
  }

  @override
  bool operator ==(Object other) =>
      other is _Rest &&
      other.draftId == draftId &&
      other.restStart == restStart &&
      other.restTotal == restTotal;

  @override
  int get hashCode => Object.hash(draftId, restStart, restTotal);
}

/// The active draft and timer rows, when both are active and agree on the
/// rest. Null otherwise.
_Rest? _agreedRest(Map<String, Object?> d, Map<String, Object?> t) {
  final draftId = t['draftId'], start = t['restStart'], total = t['restTotal'];
  if (draftId is! String ||
      d['draftId'] != draftId ||
      d['restStart'] != start ||
      d['restTotal'] != total ||
      (start != null && start is! String) ||
      total is! int) {
    return null;
  }
  return _Rest(draftId, start as String?, total);
}

/// A receipt row, read without judging it. An `issued` receipt carries the
/// rest it was issued for ([basis]). A `consumed` one also carries the
/// post-step rest, the last applied step and that step's intent.
final class _Receipt {
  const _Receipt({
    required this.status,
    required this.action,
    required this.evidence,
    this.basis,
  });
  final String status;
  final NotificationAction action;
  final Map<String, Object?> evidence;

  /// The issued basis. Null for a legacy receipt, which recorded none.
  final _Rest? basis;

  bool get legacy => !evidence.containsKey('basis');

  static _Receipt? read(Map<String, dynamic>? row) {
    if (row == null) return null;
    try {
      final evidence = _payload(row);
      final action = NotificationAction.fromJson(evidence['action']);
      final status = row['status'];
      if (action == null || (status != 'issued' && status != 'consumed')) {
        return null;
      }
      final basis = _Rest.fromJson(evidence['basis']);
      if (evidence.containsKey('basis') && basis == null) return null;
      return _Receipt(
        status: status as String,
        action: action,
        evidence: evidence,
        basis: basis,
      );
    } catch (_) {
      return null;
    }
  }

  /// The last applied step. A legacy `consumed` receipt counts as step 1.
  int? get consumedStep {
    if (status != 'consumed') return 0;
    if (legacy) return 1;
    final step = evidence['consumed_step'];
    return step is int && step >= 1 ? step : null;
  }

  /// The rest the consumed step left behind. A legacy `consumed` receipt
  /// recorded only `rest_total`: its +30s kept the token's `rest_start`.
  _Rest? get postStep {
    if (status != 'consumed') return null;
    final total = evidence['rest_total'];
    final start = legacy ? action.restStart : evidence['rest_start'];
    if (total is! int || (start != null && start is! String)) return null;
    return _Rest(action.draftId, start as String?, total);
  }
}

/// A token to post with the step its next action will carry.
final class IssuedNotificationToken {
  const IssuedNotificationToken(this.action, this.step) : assert(step >= 1);
  final NotificationAction action;
  final int step;
}

/// The one token rule (spec D5). It reuses an `issued` token while the SQL
/// rest equals its issued basis (step 1), and a `consumed` token while the SQL
/// rest equals its post-step rest (step = consumed step + 1). Otherwise it
/// issues a fresh token whose basis is the current rest.
///
/// A legacy `issued` receipt, which recorded no basis, gets one at first
/// sight: its own `rest_start` with the current SQL `restTotal`. The token is
/// kept and only the basis is added.
Future<IssuedNotificationToken?> issueNotificationToken(LocalDatabase db) =>
    db.writeTransaction((tx) async {
      final draft = await tx.localState(LocalStateKind.draft, 'active');
      final timer = await tx.localState(LocalStateKind.timer, 'active');
      if (draft?['status'] != 'active' || timer?['status'] != 'active') {
        return null;
      }
      final current = _agreedRest(_payload(draft!), _payload(timer!));
      if (current == null) return null;
      final row = await tx.localState(
        LocalStateKind.timer,
        notificationActionKey,
      );
      final receipt = _Receipt.read(row);
      if (receipt != null &&
          ownsNotificationAction(receipt.action, db, current.draftId)) {
        if (receipt.status == 'issued') {
          if (receipt.basis == current) {
            return IssuedNotificationToken(receipt.action, 1);
          }
          if (receipt.legacy && receipt.action.restStart == current.restStart) {
            await tx.putLocalState(
              LocalStateKind.timer,
              notificationActionKey,
              localBytes({
                'action': receipt.action.toJson(),
                'basis': current.toJson(),
              }),
              expectedRevision: row!['revision'] as int,
              status: 'issued',
            );
            return IssuedNotificationToken(receipt.action, 1);
          }
        } else {
          final step = receipt.consumedStep;
          if (step != null && receipt.postStep == current) {
            return IssuedNotificationToken(receipt.action, step + 1);
          }
        }
      }
      final action = NotificationAction(
        applicationId: AlkionIdentity.applicationId,
        profileId: tx.profileId,
        generation: tx.token.generation,
        draftId: current.draftId,
        restStart: current.restStart,
        // Issue-time evidence only: decoded, never compared.
        timerRevision: timer['revision'] as int,
        token: const Uuid().v4(),
      );
      await tx.putLocalState(
        LocalStateKind.timer,
        notificationActionKey,
        localBytes({'action': action.toJson(), 'basis': current.toJson()}),
        expectedRevision: row?['revision'] as int? ?? 0,
        status: 'issued',
      );
      return IssuedNotificationToken(action, 1);
    }, expected: db.token);

/// [issueNotificationToken] without its step, for callers that post the bare
/// token.
Future<NotificationAction?> issueNotificationAction(LocalDatabase db) async =>
    (await issueNotificationToken(db))?.action;

/// The rest a decided intent committed, read back from SQL.
final class CommittedRestChange {
  const CommittedRestChange(
    this.restStart,
    this.restTotal,
    this.draftRevision, {
    this.restEndedAt,
  });

  /// Null after a Skip.
  final DateTime? restStart;
  final int restTotal, draftRevision;

  /// When the rest ended: the Skip's tap time capped at the due time, or the
  /// committed draft's existing value after a +30s.
  final DateTime? restEndedAt;
}

enum NotificationRefusal {
  staleGeneration('stale_generation'),
  foreign('foreign'),
  draftNotActive('draft_not_active'),
  tokenSuperseded('token_superseded'),
  basisChanged('basis_changed'),
  conflict('conflict'),
  gap('gap'),
  late('late'),
  clock('clock');

  const NotificationRefusal(this.wire);
  final String wire;
}

enum NotificationOutcome { applied, duplicate, refused }

/// How SQL decided one intent. Only [NotificationOutcome.applied] wrote.
final class NotificationConsumption {
  const NotificationConsumption.applied(CommittedRestChange this.change)
    : outcome = NotificationOutcome.applied,
      reason = null;

  /// [change] is the committed rest while SQL still holds exactly what that
  /// step committed, so an uncertain COMMIT can adopt it.
  const NotificationConsumption.duplicate([this.change])
    : outcome = NotificationOutcome.duplicate,
      reason = null;
  const NotificationConsumption.refused(NotificationRefusal this.reason)
    : outcome = NotificationOutcome.refused,
      change = null;

  final NotificationOutcome outcome;
  final NotificationRefusal? reason;
  final CommittedRestChange? change;

  /// The trace marker's verb: `applied`, `duplicate` or `refused <reason>`.
  String get marker => reason == null
      ? outcome.name
      : '${NotificationOutcome.refused.name} ${reason!.wire}';
}

/// A tap from an older build's +30s, which reached the owner directly with a
/// bare token (spec D2). It is never journaled: it becomes step 1 of an add,
/// tapped now, under a fresh intent ID.
NotificationIntent legacyNotificationIntent(
  NotificationAction action, {
  DateTime? now,
}) => NotificationIntent(
  intentId: const Uuid().v4(),
  actionId: AlkionIdentity.addRestAction,
  kind: NotificationIntentKind.add,
  tappedAt: (now ?? DateTime.now()).toUtc(),
  payload: NotificationEnvelope(action: action, step: 1),
);

/// How far in the future a tap time may lie (a device clock adjustment).
const notificationTapClockSkew = Duration(minutes: 2);

DateTime? _instant(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// The existing runtime is the only writer. One write transaction decides
/// [intent] against its token's receipt (spec D5): the step must follow the
/// receipt's last step, the SQL rest must equal that step's basis, and the
/// rest must have been running at the tap. Draft, timer and receipt commit
/// together; a duplicate or a refusal writes nothing. No domain row,
/// operation or outbox entry is written.
Future<NotificationConsumption> consumeNotificationIntent(
  LocalDatabase db,
  NotificationIntent intent, {
  DateTime? now,
}) async {
  final action = intent.payload.action;
  if (action.applicationId != AlkionIdentity.applicationId ||
      action.profileId != db.profileId) {
    return const NotificationConsumption.refused(NotificationRefusal.foreign);
  }
  if (action.generation != db.token.generation) {
    return const NotificationConsumption.refused(
      NotificationRefusal.staleGeneration,
    );
  }
  return db.writeTransaction((tx) async {
    NotificationConsumption refused(NotificationRefusal reason) =>
        NotificationConsumption.refused(reason);
    final draft = await tx.localState(LocalStateKind.draft, 'active');
    final timer = await tx.localState(LocalStateKind.timer, 'active');
    if (draft?['status'] != 'active' || timer?['status'] != 'active') {
      return refused(NotificationRefusal.draftNotActive);
    }
    final d = _payload(draft!), t = _payload(timer!);
    if (d['draftId'] != action.draftId || t['draftId'] != action.draftId) {
      return refused(NotificationRefusal.draftNotActive);
    }
    final row = await tx.localState(
      LocalStateKind.timer,
      notificationActionKey,
    );
    final receipt = _Receipt.read(row);
    final consumed = receipt?.consumedStep;
    if (receipt == null ||
        consumed == null ||
        receipt.action.encode() != action.encode()) {
      return refused(NotificationRefusal.tokenSuperseded);
    }
    final current = _agreedRest(d, t);
    final step = intent.payload.step;
    if (step <= consumed) {
      // The receipt answers "did step k commit, and with which intent?".
      if (step != consumed ||
          receipt.legacy ||
          receipt.evidence['last_intent_id'] != intent.intentId ||
          receipt.evidence['kind'] != intent.kind.wire) {
        return refused(NotificationRefusal.conflict);
      }
      final post = receipt.postStep;
      final revision = receipt.evidence['draft_revision'];
      return NotificationConsumption.duplicate(
        post != null && post == current && draft['revision'] == revision
            ? CommittedRestChange(
                _instant(post.restStart),
                post.restTotal,
                revision as int,
                restEndedAt: _instant(receipt.evidence['rest_ended_at']),
              )
            : null,
      );
    }
    if (step > consumed + 1) return refused(NotificationRefusal.gap);
    // A legacy issued receipt is judged at first sight: its own rest_start
    // with the current SQL restTotal.
    final basis = consumed == 0
        ? receipt.basis ??
              (current == null
                  ? null
                  : _Rest(action.draftId, action.restStart, current.restTotal))
        : receipt.postStep;
    if (current == null || basis == null || basis != current) {
      return refused(NotificationRefusal.basisChanged);
    }
    final start = _instant(current.restStart);
    if (start == null || current.restTotal < 1) {
      return refused(NotificationRefusal.late);
    }
    final tapped = intent.tappedAt;
    if (tapped.isBefore(start) ||
        tapped.isAfter((now ?? DateTime.now()).add(notificationTapClockSkew))) {
      return refused(NotificationRefusal.clock);
    }
    final due = start.add(Duration(seconds: current.restTotal));
    if (!tapped.isBefore(due)) return refused(NotificationRefusal.late);

    final DateTime? restStart, endedAt;
    final int total;
    switch (intent.kind) {
      case NotificationIntentKind.add:
        restStart = start;
        total = current.restTotal + 30;
        endedAt = _instant(t['restEndedAt']);
        d['restTotal'] = t['restTotal'] = total;
      case NotificationIntentKind.skip:
        // stopRest evaluated at the tap time, in the stored start's zone.
        final ended = start.isUtc ? tapped.toUtc() : tapped.toLocal();
        restStart = null;
        total = 0;
        endedAt = ended;
        d['restStart'] = t['restStart'] = null;
        d['restTotal'] = t['restTotal'] = 0;
        d['restEndedAt'] = t['restEndedAt'] = ended.toIso8601String();
    }
    final revision = await tx.putLocalState(
      LocalStateKind.draft,
      'active',
      localBytes(d),
      expectedRevision: draft['revision'] as int,
    );
    await tx.putLocalState(
      LocalStateKind.timer,
      'active',
      localBytes(t),
      expectedRevision: timer['revision'] as int,
    );
    await tx.putLocalState(
      LocalStateKind.timer,
      notificationActionKey,
      localBytes({
        'action': action.toJson(),
        'basis': (receipt.basis ?? basis).toJson(),
        'consumed_step': step,
        'last_intent_id': intent.intentId,
        'kind': intent.kind.wire,
        'rest_start': t['restStart'],
        'rest_total': total,
        'rest_ended_at': t['restEndedAt'],
        'draft_revision': revision,
      }),
      expectedRevision: row!['revision'] as int,
      status: 'consumed',
    );
    return NotificationConsumption.applied(
      CommittedRestChange(restStart, total, revision, restEndedAt: endedAt),
    );
  }, expected: db.token);
}

/// An older build's +30s tap at the database: [legacyNotificationIntent]
/// decided by [consumeNotificationIntent]. Returns the committed rest, or
/// null when SQL refused it.
Future<CommittedRestChange?> consumeNotificationAction(
  LocalDatabase db,
  NotificationAction action, {
  DateTime? now,
}) async => (await consumeNotificationIntent(
  db,
  legacyNotificationIntent(action, now: now),
  now: now,
)).change;
