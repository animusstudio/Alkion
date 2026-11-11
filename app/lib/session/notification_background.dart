import 'dart:io';
import 'dart:ui'; // DartPluginRegistrant, IsolateNameServer

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'notification_envelope.dart';
import 'notification_journal.dart';
import 'workout_notification_render.dart';

/// The plugin's background handler for +30s and Skip rest: a messenger with a
/// durable intent journal. It never opens the profile, never touches SQLite,
/// never initializes the plugin and never requests permission; the main
/// isolate stays the only SQL owner
/// (`test/session/notification_import_guard_test.dart`).
///
/// Each delivery journals the tap, then either wakes the owner through
/// [notificationPortName] or, with no owner, renders a provisional mirror
/// folded from the journal, and re-checks the port after rendering.

/// Compiled in only for the private Dev APK (`--dart-define`).
const notificationTraceEnabled = bool.fromEnvironment(
  'ALKION_NOTIFICATION_TRACE',
);

/// What one delivery did.
enum NotificationBackgroundOutcome {
  /// Not one of the two actions, or the payload did not decode in bounds.
  ignored,

  /// The journal append failed or was refused: nothing rendered.
  notJournaled,

  /// Journaled, and an owner port existed: the owner renders.
  handedOff,

  /// Journaled and rendered provisionally.
  rendered,

  /// Journaled, but nothing could be rendered (no view to fold, no payload
  /// that fits, or the render failed).
  unrendered,
}

/// The mirror the background would show for [token]: folded from the journal
/// entries on that token, never from a tapped payload's own view. The base is
/// the view and step of the lowest-step entry; then the first arrival per
/// step (by `tapped_at`, then `intent_id`), in step order, up to the first
/// gap. +30s adds 30 seconds; Skip, or a tap at or past the folded rest end,
/// ends the rest. The result carries the same token and the next step (last
/// folded step + 1). Null when no entry is on [token] or the base has no view.
NotificationEnvelope? foldNotificationIntents(
  Iterable<NotificationIntent> intents,
  NotificationAction token,
) {
  final key = token.encode();
  final matching = [
    for (final intent in intents)
      if (intent.payload.action.encode() == key) intent,
  ]..sort(compareNotificationIntents);
  if (matching.isEmpty) return null;
  final base = matching.first;
  var view = base.payload.view;
  if (view == null) return null;
  final firstPerStep = <int, NotificationIntent>{};
  for (final intent in matching) {
    firstPerStep.putIfAbsent(intent.payload.step, () => intent);
  }
  var step = base.payload.step;
  var last = step - 1;
  for (
    var intent = firstPerStep[step];
    intent != null;
    intent = firstPerStep[step]
  ) {
    last = step;
    final restStart = view!.restStart;
    final end = restStart?.add(Duration(seconds: view.restTotal));
    if (restStart == null ||
        intent.kind == NotificationIntentKind.skip ||
        !intent.tappedAt.isBefore(end!)) {
      view = _elapsed(view);
      break;
    }
    view = _withRestTotal(view, view.restTotal + 30);
    step++;
  }
  return NotificationEnvelope(action: token, step: last + 1, view: view);
}

NotificationView _withRestTotal(NotificationView view, int restTotal) =>
    NotificationView(
      title: view.title,
      restBody: view.restBody,
      elapsedBody: view.elapsedBody,
      startedAt: view.startedAt,
      restStart: view.restStart,
      restTotal: restTotal,
      locale: view.locale,
    );

NotificationView _elapsed(NotificationView view) => NotificationView(
  title: view.title,
  restBody: view.restBody,
  elapsedBody: view.elapsedBody,
  startedAt: view.startedAt,
  locale: view.locale,
);

/// The background's collaborators. [NotificationBackground.platform] wires the
/// real ones; tests inject the port, renderer, clock and directory.
final class NotificationBackground {
  NotificationBackground({
    required this.journalDirectory,
    required this.wakeOwner,
    required this.render,
    required this.exact,
    DateTime Function()? clock,
    String Function()? newIntentId,
    this.checkpoint,
    void Function(String marker)? trace,
  }) : clock = clock ?? (() => DateTime.now().toUtc()),
       newIntentId = newIntentId ?? const Uuid().v4,
       trace = trace ?? (notificationTraceEnabled ? _print : null);

  /// The production wiring: path_provider's support (files) directory, the
  /// `IsolateNameServer` port and [renderRestMirror] on the plugin as the
  /// dispatcher registered it. [plugin] is injectable for channel tests.
  factory NotificationBackground.platform({
    FlutterLocalNotificationsPlugin? plugin,
    Future<Directory> Function()? supportDirectory,
  }) {
    final notifications = plugin ?? FlutterLocalNotificationsPlugin();
    return NotificationBackground(
      journalDirectory: () async => notificationJournalDirectory(
        notificationSupportRoot(
          await (supportDirectory ?? getApplicationSupportDirectory)(),
        ),
      ),
      wakeOwner: wakeNotificationOwner,
      render: (mirror) => renderRestMirror(notifications, mirror),
      exact: () async =>
          await notifications
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.canScheduleExactNotifications() ==
          true,
    );
  }

  /// The journal directory, from [notificationJournalDirectory].
  final Future<Directory> Function() journalDirectory;

  /// Sends the wake-up when an owner port is registered; true if it did.
  final bool Function() wakeOwner;
  final Future<void> Function(RestMirror mirror) render;

  /// Whether exact alarms are allowed. The renderer never checks this itself.
  final Future<bool> Function() exact;
  final DateTime Function() clock;
  final String Function() newIntentId;

  /// The journal's crash-test seam ([NotificationJournal.checkpoint]).
  final Future<void> Function(String phase)? checkpoint;
  final void Function(String marker)? trace;

  // ignore: avoid_print
  static void _print(String marker) => print(marker);

  bool _wake() {
    try {
      return wakeOwner();
    } catch (_) {
      return false;
    }
  }

  void _mark(String event, NotificationIntent intent) => trace?.call(
    'alkion-notif $event ${intent.intentId.substring(0, 8)} '
    '${intent.payload.step} ${intent.kind.wire}',
  );

  /// Handles one delivery. Never throws.
  Future<NotificationBackgroundOutcome> _handle(
    NotificationResponse response,
    DateTime tappedAt,
    String intentId,
  ) async {
    final kind = notificationIntentKindFor(response.actionId);
    final envelope = NotificationEnvelope.decode(response.payload);
    if (kind == null || envelope == null) {
      return NotificationBackgroundOutcome.ignored;
    }
    final intent = NotificationIntent(
      intentId: intentId,
      actionId: response.actionId!,
      kind: kind,
      tappedAt: tappedAt,
      payload: envelope,
    );
    _mark('received', intent);
    final NotificationJournal journal;
    try {
      journal = NotificationJournal(
        await journalDirectory(),
        checkpoint: checkpoint,
        clock: clock,
      );
      await journal.append(intent);
    } catch (_) {
      return NotificationBackgroundOutcome.notJournaled;
    }
    _mark('journaled', intent);
    if (_wake()) {
      _mark('woke', intent);
      return NotificationBackgroundOutcome.handedOff;
    }
    var outcome = NotificationBackgroundOutcome.unrendered;
    try {
      final entries = await journal.read();
      final folded = foldNotificationIntents([
        for (final entry in entries)
          if (entry.intent case final readable?) readable,
      ], envelope.action);
      final payload = folded?.encodeWithinBudget();
      if (folded != null && payload != null) {
        await render(
          RestMirror(
            view: folded.view!,
            payload: payload,
            actionable: envelope.action.restStart != null,
            alertAtRestEnd: true,
            exact: await exact(),
            now: clock(),
          ),
        );
        _mark('rendered', intent);
        outcome = NotificationBackgroundOutcome.rendered;
      }
    } catch (_) {
      outcome = NotificationBackgroundOutcome.unrendered;
    }
    // An owner that appeared during the render corrects the mirror.
    if (_wake()) _mark('woke', intent);
    return outcome;
  }
}

/// Wakes the SQL owner when its port is registered. A stale port with no
/// listener swallows the message: the entry waits for the next drain.
bool wakeNotificationOwner() {
  final port = IsolateNameServer.lookupPortByName(notificationPortName);
  if (port == null) return false;
  port.send(notificationWakeMessage);
  return true;
}

/// The one module-level tail: deliveries run in arrival order, even though
/// the plugin's dispatcher calls the handler without awaiting it.
Future<void> _tail = Future<void>.value();

/// Queues [response] on the module tail. `tapped_at` and the intent ID are
/// taken on arrival. [background] defaults to the platform wiring.
Future<NotificationBackgroundOutcome> deliverNotificationResponse(
  NotificationResponse response, {
  NotificationBackground? background,
}) {
  final handler = background ?? NotificationBackground.platform();
  final tappedAt = handler.clock().toUtc();
  final intentId = handler.newIntentId();
  final work = _tail.then((_) => handler._handle(response, tappedAt, intentId));
  _tail = work.then<void>((_) {}, onError: (Object _) {});
  return work;
}

/// The plugin's background entry point
/// (`onDidReceiveBackgroundNotificationResponse`). Registers the Dart side of
/// the pub plugins first (the dispatcher does not), then queues the delivery.
@pragma('vm:entry-point')
void onBackgroundNotificationResponse(NotificationResponse response) {
  DartPluginRegistrant.ensureInitialized();
  deliverNotificationResponse(response);
}
