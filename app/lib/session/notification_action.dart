import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../domain/evidence.dart';
import '../identity/alkion_identity.dart';
import '../store/local_store.dart';

const notificationActionKey = 'notification-action';

/// A capability issued by the selected SQL owner, never a storage path.
final class NotificationAction {
  const NotificationAction({
    required this.applicationId,
    required this.profileId,
    required this.generation,
    required this.draftId,
    required this.restStart,
    required this.timerRevision,
    required this.token,
  });
  final String applicationId, profileId, draftId, token;
  final String? restStart;
  final int generation, timerRevision;

  Map<String, Object?> toJson() => {
    'format': 'alkion-notification-action/1',
    'application_id': applicationId,
    'profile_id': profileId,
    'generation': generation,
    'draft_id': draftId,
    'rest_start': restStart,
    'timer_revision': timerRevision,
    'token': token,
  };
  String encode() => jsonEncode(toJson());

  static NotificationAction? decode(String? payload) {
    if (payload == null || payload.length > 4096) return null;
    try {
      final value = jsonDecode(payload) as Map;
      if (value.length != 8 ||
          value['format'] != 'alkion-notification-action/1' ||
          value['application_id'] is! String ||
          value['profile_id'] is! String ||
          value['draft_id'] is! String ||
          value['token'] is! String ||
          value['generation'] is! int ||
          value['generation'] < 1 ||
          value['timer_revision'] is! int ||
          value['timer_revision'] < 1 ||
          (value['rest_start'] != null &&
              DateTime.tryParse(value['rest_start'] as String) == null)) {
        return null;
      }
      for (final key in ['application_id', 'profile_id', 'draft_id', 'token']) {
        if ((value[key] as String).isEmpty ||
            (value[key] as String).length > 256) {
          return null;
        }
      }
      return NotificationAction(
        applicationId: value['application_id'] as String,
        profileId: value['profile_id'] as String,
        generation: value['generation'] as int,
        draftId: value['draft_id'] as String,
        restStart: value['rest_start'] as String?,
        timerRevision: value['timer_revision'] as int,
        token: value['token'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  bool owns(LocalDatabase db, String currentDraft) =>
      applicationId == AlkionIdentity.applicationId &&
      profileId == db.profileId &&
      generation == db.token.generation &&
      draftId == currentDraft;
}

Map<String, Object?> _payload(Map<String, dynamic> row) =>
    Map<String, Object?>.from(
      jsonDecode(utf8.decode((row['payload_bytes'] as List).cast<int>()))
          as Map,
    );

/// Reuses an unchanged issued token. A changed SQL timer gets a fresh token.
Future<NotificationAction?> issueNotificationAction(LocalDatabase db) =>
    db.writeTransaction((tx) async {
      final draft = await tx.localState(LocalStateKind.draft, 'active');
      final timer = await tx.localState(LocalStateKind.timer, 'active');
      if (draft?['status'] != 'active' || timer?['status'] != 'active') {
        return null;
      }
      final d = _payload(draft!), t = _payload(timer!);
      if (d['draftId'] != t['draftId'] ||
          d['restStart'] != t['restStart'] ||
          d['restTotal'] != t['restTotal']) {
        return null;
      }
      final receipt = await tx.localState(
        LocalStateKind.timer,
        notificationActionKey,
      );
      final old = receipt == null ? null : _payload(receipt);
      final issued = NotificationAction.decode(jsonEncode(old?['action']));
      if (receipt?['status'] == 'issued' &&
          issued != null &&
          issued.owns(db, d['draftId'] as String) &&
          issued.restStart == t['restStart'] &&
          issued.timerRevision == timer['revision']) {
        return issued;
      }
      final action = NotificationAction(
        applicationId: AlkionIdentity.applicationId,
        profileId: tx.profileId,
        generation: tx.token.generation,
        draftId: d['draftId'] as String,
        restStart: t['restStart'] as String?,
        timerRevision: timer['revision'] as int,
        token: const Uuid().v4(),
      );
      await tx.putLocalState(
        LocalStateKind.timer,
        notificationActionKey,
        localBytes({'action': action.toJson()}),
        expectedRevision: receipt?['revision'] as int? ?? 0,
        status: 'issued',
      );
      return action;
    }, expected: db.token);

final class CommittedRestChange {
  const CommittedRestChange(this.restStart, this.restTotal, this.draftRevision);
  final DateTime restStart;
  final int restTotal, draftRevision;
}

/// The existing runtime is the only writer. Token consumption, draft and timer
/// commit together. Duplicate delivery can reconcile the same committed result.
Future<CommittedRestChange?> consumeNotificationAction(
  LocalDatabase db,
  NotificationAction action, {
  DateTime? now,
}) async {
  if (action.applicationId != AlkionIdentity.applicationId ||
      action.profileId != db.profileId ||
      action.generation != db.token.generation ||
      action.restStart == null) {
    return null;
  }
  return db.writeTransaction((tx) async {
    final draft = await tx.localState(LocalStateKind.draft, 'active');
    final timer = await tx.localState(LocalStateKind.timer, 'active');
    final receipt = await tx.localState(
      LocalStateKind.timer,
      notificationActionKey,
    );
    if (draft?['status'] != 'active' ||
        timer?['status'] != 'active' ||
        receipt == null) {
      return null;
    }
    final d = _payload(draft!), t = _payload(timer!);
    final evidence = _payload(receipt);
    final issued = NotificationAction.decode(jsonEncode(evidence['action']));
    if (issued == null ||
        issued.encode() != action.encode() ||
        !action.owns(db, d['draftId'] as String) ||
        t['draftId'] != action.draftId ||
        d['restStart'] != action.restStart ||
        t['restStart'] != action.restStart ||
        d['restTotal'] != t['restTotal'] ||
        t['restTotal'] is! int) {
      return null;
    }
    final start = DateTime.parse(action.restStart!);
    final total = t['restTotal'] as int;
    if (receipt['status'] == 'consumed') {
      if (timer['revision'] == action.timerRevision + 1 &&
          evidence['draft_revision'] == draft['revision'] &&
          evidence['rest_total'] == total) {
        return CommittedRestChange(start, total, draft['revision'] as int);
      }
      return null;
    }
    if (receipt['status'] != 'issued' ||
        timer['revision'] != action.timerRevision ||
        total < 1 ||
        !(now ?? DateTime.now()).isBefore(
          start.add(Duration(seconds: total)),
        )) {
      return null;
    }
    d['restTotal'] = total + 30;
    t['restTotal'] = total + 30;
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
      expectedRevision: action.timerRevision,
    );
    await tx.putLocalState(
      LocalStateKind.timer,
      notificationActionKey,
      localBytes({
        'action': action.toJson(),
        'draft_revision': revision,
        'rest_total': total + 30,
      }),
      expectedRevision: receipt['revision'] as int,
      status: 'consumed',
    );
    return CommittedRestChange(start, total + 30, revision);
  }, expected: db.token);
}
