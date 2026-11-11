import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../identity/alkion_identity.dart';

/// Pure notification values shared by the SQL owner and the background
/// handler. This module never imports store, SQL or Flutter UI code
/// (`test/session/notification_import_guard_test.dart` proves it), so the
/// plugin's secondary engine can load it without touching the profile.

/// The Android notification payload limit, counted in UTF-8 bytes.
const notificationPayloadByteLimit = 4096;

const notificationActionFormat = 'alkion-notification-action/1';
const notificationPayloadFormat = 'alkion-notification-payload/1';
const notificationIntentFormat = 'alkion-notification-intent/1';

/// The message a background handler sends to the owner's port: "drain the
/// journal". It carries no data; the journal is the only channel for intent.
const notificationWakeMessage = 'alkion-notification-wake/1';

/// The `IsolateNameServer` name of the SQL owner's wake-up port.
String get notificationPortName =>
    '${AlkionIdentity.applicationId}.notification-intents';

/// The support root a support directory names, without Flutter: the same
/// derivation as `checkedAlkionSupportRoot` in `main.dart` (a directory
/// already named for the application is the root, otherwise the root is its
/// application-named child). The background passes path_provider's support
/// directory here; the owner passes its checked root straight to
/// [notificationJournalDirectory].
Directory notificationSupportRoot(Directory supportDirectory) =>
    p.basename(supportDirectory.path) == AlkionIdentity.applicationId
    ? supportDirectory
    : Directory(p.join(supportDirectory.path, AlkionIdentity.applicationId));

/// The only journal-path function. Both engines pass their support root: the
/// owner its checked root, the background its derivation from the files
/// directory. The journal is a sibling of that root (like the first-entry
/// journal), so no profile or restore inventory ever sees it.
Directory notificationJournalDirectory(Directory supportRoot) => Directory(
  p.join(
    p.dirname(p.normalize(p.absolute(supportRoot.path))),
    '.${AlkionIdentity.applicationId}-notification-intents',
  ),
);

int utf8Length(String value) => utf8.encode(value).length;

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
    'format': notificationActionFormat,
    'application_id': applicationId,
    'profile_id': profileId,
    'generation': generation,
    'draft_id': draftId,
    'rest_start': restStart,
    'timer_revision': timerRevision,
    'token': token,
  };
  String encode() => jsonEncode(toJson());

  /// The bare token. Its bound stays the historical UTF-16 length; the
  /// envelope decoder is the one that counts UTF-8 bytes.
  static NotificationAction? decode(String? payload) {
    if (payload == null || payload.length > notificationPayloadByteLimit) {
      return null;
    }
    try {
      return fromJson(jsonDecode(payload));
    } catch (_) {
      return null;
    }
  }

  static NotificationAction? fromJson(Object? json) {
    try {
      if (json is! Map) return null;
      final value = json;
      if (value.length != 8 ||
          value['format'] != notificationActionFormat ||
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
}

/// Presentation state carried in a payload: never authority. Labels are not
/// stored; the renderer derives them from [locale].
final class NotificationView {
  const NotificationView({
    required this.title,
    required this.restBody,
    required this.elapsedBody,
    required this.startedAt,
    this.restStart,
    this.restTotal = 0,
    this.locale,
  });

  /// The workout name.
  final String title;

  /// The rest countdown's body: the next-set line, else the localized "Rest".
  final String restBody;

  /// The rest-end post's body, shown on the elapsed chronometer once the rest
  /// is over: the next-set line, else the workout name.
  final String elapsedBody;
  final DateTime startedAt;
  final DateTime? restStart;
  final int restTotal;
  final String? locale;

  NotificationView withTitle(String value) => NotificationView(
    title: value,
    restBody: restBody,
    elapsedBody: elapsedBody,
    startedAt: startedAt,
    restStart: restStart,
    restTotal: restTotal,
    locale: locale,
  );

  Map<String, Object?> toJson() => {
    'title': title,
    'rest_body': restBody,
    'elapsed_body': elapsedBody,
    'started_at': startedAt.toUtc().toIso8601String(),
    'rest_start': restStart?.toUtc().toIso8601String(),
    'rest_total': restTotal,
    'locale': locale,
  };

  static NotificationView? fromJson(Object? json) {
    if (json is! Map || json.length != 7) return null;
    final title = json['title'],
        restBody = json['rest_body'],
        elapsedBody = json['elapsed_body'],
        startedAt = json['started_at'],
        restStart = json['rest_start'],
        restTotal = json['rest_total'],
        locale = json['locale'];
    if (title is! String ||
        restBody is! String ||
        elapsedBody is! String ||
        startedAt is! String ||
        (restStart != null && restStart is! String) ||
        restTotal is! int ||
        restTotal < 0 ||
        (locale != null && (locale is! String || locale.isEmpty))) {
      return null;
    }
    final started = _utc(startedAt);
    final rest = restStart == null ? null : _utc(restStart as String);
    if (started == null || (restStart != null && rest == null)) return null;
    return NotificationView(
      title: title,
      restBody: restBody,
      elapsedBody: elapsedBody,
      startedAt: started,
      restStart: rest,
      restTotal: restTotal,
      locale: locale as String?,
    );
  }
}

DateTime? _utc(String value) {
  final parsed = DateTime.tryParse(value);
  return parsed != null && parsed.isUtc ? parsed : null;
}

/// The posted payload: `{format, action, step, view}`. A bare
/// [notificationActionFormat] token from an older build decodes as step 1
/// with no view.
final class NotificationEnvelope {
  const NotificationEnvelope({
    required this.action,
    required this.step,
    this.view,
  }) : assert(step >= 1);
  final NotificationAction action;

  /// The ordinal of the next action on [action]'s token, from 1.
  final int step;
  final NotificationView? view;

  Map<String, Object?> toJson() => {
    'format': notificationPayloadFormat,
    'action': action.toJson(),
    'step': step,
    if (view != null) 'view': view!.toJson(),
  };

  /// The exact payload, or null when it exceeds the byte limit.
  String? encode() {
    final payload = jsonEncode(toJson());
    return utf8Length(payload) <= notificationPayloadByteLimit ? payload : null;
  }

  /// Fits the payload into [notificationPayloadByteLimit] UTF-8 bytes: first
  /// whole, then with the view's title shortened on a code point boundary,
  /// then without a view (the tap still journals but cannot render). A title
  /// is never shortened to nothing: the view is dropped instead. Null only if
  /// the action and step alone do not fit.
  String? encodeWithinBudget() {
    final whole = encode();
    if (whole != null || view == null) return whole;
    final title = view!.title.runes.toList();
    String? fitted;
    var low = 1, high = title.length - 1;
    while (low <= high) {
      final keep = (low + high) ~/ 2;
      final payload = NotificationEnvelope(
        action: action,
        step: step,
        view: view!.withTitle(String.fromCharCodes(title.take(keep))),
      ).encode();
      if (payload == null) {
        high = keep - 1;
      } else {
        fitted = payload;
        low = keep + 1;
      }
    }
    return fitted ?? NotificationEnvelope(action: action, step: step).encode();
  }

  /// Accepts the envelope and the legacy bare token, both within the UTF-8
  /// byte limit.
  static NotificationEnvelope? decode(String? payload) {
    if (payload == null || utf8Length(payload) > notificationPayloadByteLimit) {
      return null;
    }
    try {
      return fromJson(jsonDecode(payload));
    } catch (_) {
      return null;
    }
  }

  static NotificationEnvelope? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['format'] == notificationActionFormat) {
      final action = NotificationAction.fromJson(json);
      return action == null
          ? null
          : NotificationEnvelope(action: action, step: 1);
    }
    if (json['format'] != notificationPayloadFormat ||
        json.length != (json.containsKey('view') ? 4 : 3)) {
      return null;
    }
    final action = NotificationAction.fromJson(json['action']);
    final step = json['step'];
    if (action == null || step is! int || step < 1) return null;
    NotificationView? view;
    if (json.containsKey('view')) {
      view = NotificationView.fromJson(json['view']);
      if (view == null) return null;
    }
    return NotificationEnvelope(action: action, step: step, view: view);
  }
}

enum NotificationIntentKind {
  add('add'),
  skip('skip');

  const NotificationIntentKind(this.wire);
  final String wire;

  static NotificationIntentKind? fromWire(Object? value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// One journaled tap: `{format, intent_id, action_id, kind, tapped_at,
/// payload}`. [tappedAt] is when the background handler ran, in UTC.
final class NotificationIntent {
  const NotificationIntent({
    required this.intentId,
    required this.actionId,
    required this.kind,
    required this.tappedAt,
    required this.payload,
  });
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  final String intentId, actionId;
  final NotificationIntentKind kind;
  final DateTime tappedAt;
  final NotificationEnvelope payload;

  Map<String, Object?> toJson() => {
    'format': notificationIntentFormat,
    'intent_id': intentId,
    'action_id': actionId,
    'kind': kind.wire,
    'tapped_at': tappedAt.toUtc().toIso8601String(),
    'payload': payload.toJson(),
  };
  String encode() => jsonEncode(toJson());

  static NotificationIntent? decode(String source) {
    try {
      final json = jsonDecode(source);
      if (json is! Map ||
          json.length != 6 ||
          json['format'] != notificationIntentFormat) {
        return null;
      }
      final intentId = json['intent_id'], actionId = json['action_id'];
      final kind = NotificationIntentKind.fromWire(json['kind']);
      final tappedAt = json['tapped_at'];
      if (intentId is! String ||
          !_uuid.hasMatch(intentId) ||
          actionId is! String ||
          actionId.isEmpty ||
          actionId.length > 256 ||
          kind == null ||
          tappedAt is! String) {
        return null;
      }
      final tapped = _utc(tappedAt);
      final payload = NotificationEnvelope.fromJson(json['payload']);
      if (tapped == null || payload == null) return null;
      return NotificationIntent(
        intentId: intentId,
        actionId: actionId,
        kind: kind,
        tappedAt: tapped,
        payload: payload,
      );
    } catch (_) {
      return null;
    }
  }
}
