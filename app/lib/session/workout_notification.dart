import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../identity/alkion_identity.dart';
import 'notification_background.dart';
import 'notification_envelope.dart';
import 'workout_notification_render.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

export 'workout_notification_render.dart';

const _kNotifId = workoutNotificationId;
final _kChannelId = AlkionIdentity.notificationChannel;
final _kRestEndChannelId = AlkionIdentity.restEndChannel;

/// The status-bar glyph: a monochrome vector in the Android drawables.
const kNotificationSmallIcon = '@drawable/ic_stat_alkion';

enum NotificationLimitation { denied, unavailable }

/// The owner's Android OS mirror. It posts the payload envelope (token, next
/// step and view) and registers the background handler; it never writes SQL.
/// +30s and Skip rest are background actions: the plugin hands them to
/// [onBackgroundNotificationResponse] in its secondary engine, a headless
/// messenger that only journals the tap. The `SessionManager` that owns this
/// mirror is the only SQL writer and applies journaled taps.
class WorkoutNotification extends ChangeNotifier {
  WorkoutNotification({
    @visibleForTesting FlutterLocalNotificationsPlugin? plugin,
    @visibleForTesting bool? isAndroid,
    @visibleForTesting void Function(String marker)? trace,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _isAndroid = isAndroid ?? Platform.isAndroid,
       _trace = trace ?? (notificationTraceEnabled ? _print : null);

  // ignore: avoid_print
  static void _print(String marker) => print(marker);
  final void Function(String marker)? _trace;

  final FlutterLocalNotificationsPlugin _plugin;
  final bool _isAndroid;
  bool get supported => _isAndroid;
  String? locale;
  bool _ready = false, _closed = false;
  String? _lastShown;
  Future<void> _tail = Future.value();
  NotificationLimitation? _limitation;
  NotificationLimitation? get limitation => _limitation;
  void _status(NotificationLimitation? value) {
    if (_limitation == value) return;
    _limitation = value;
    notifyListeners();
  }

  Future<NotificationResponse?> init({
    required void Function(NotificationResponse) onResponse,
  }) async {
    if (!_isAndroid || _closed) return null;
    try {
      final initialized = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings(kNotificationSmallIcon),
        ),
        onDidReceiveNotificationResponse: onResponse,
        // +30s and Skip rest arrive here, in the plugin's secondary engine.
        onDidReceiveBackgroundNotificationResponse:
            onBackgroundNotificationResponse,
      );
      if (initialized != true) {
        _status(NotificationLimitation.unavailable);
        return null;
      }
      await _android?.createNotificationChannel(
        AndroidNotificationChannel(
          _kChannelId,
          notifString(locale, 'channel'),
          importance: Importance.low,
          playSound: false,
        ),
      );
      await _android?.createNotificationChannel(
        AndroidNotificationChannel(
          _kRestEndChannelId,
          notifString(locale, 'restEndChannel'),
          description: notifString(locale, 'restEndChannelDescription'),
          importance: Importance.high,
          playSound: false,
          enableVibration: true,
        ),
      );
      tzdata.initializeTimeZones();
      _ready = true;
      final launch = await _plugin.getNotificationAppLaunchDetails();
      return launch?.didNotificationLaunchApp == true
          ? launch?.notificationResponse
          : null;
    } catch (_) {
      _status(NotificationLimitation.unavailable);
      return null;
    }
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  Future<void> _serialize(Future<void> Function() operation) {
    final work = _tail.then((_) => operation());
    _tail = work.then<void>((_) {}, onError: (Object error) {});
    return work;
  }

  /// Whether Android currently allows notifications; null when that is
  /// unknown (not Android, not initialized, closed, or the query failed).
  Future<bool?> notificationsEnabled() async {
    if (!_ready || _closed) return null;
    try {
      return await _android?.areNotificationsEnabled();
    } catch (_) {
      return null;
    }
  }

  /// Asks Android for permission to notify (the system prompt on Android 13
  /// and later). Only the first-start explainer calls this; [showFor] never
  /// prompts, so the dialog cannot appear mid-workout.
  Future<bool> requestPermission() async {
    if (!_ready || _closed) return false;
    try {
      return await _android?.requestNotificationsPermission() == true;
    } catch (_) {
      return false;
    }
  }

  /// Mirrors the workout. During a rest it counts down and schedules the
  /// rest-end post: the alert variant ([buildRestEndAndroidDetails]) when
  /// [alertAtRestEnd], otherwise the quiet elapsed mirror. [nextName] names
  /// the next pending exercise (null when the plan is done).
  ///
  /// The payload is the envelope for [action]'s token with [step], the step
  /// its next tap carries, and the mirror's view ([workoutNotificationPayload]).
  /// An unchanged mirror is not posted again unless [force]: the owner forces
  /// a render after every decided intent and at open, so a provisional
  /// mirror the background posted is always replaced.
  Future<void> showFor({
    required String name,
    required DateTime startedAt,
    DateTime? restStart,
    int restTotal = 0,
    NotificationAction? action,
    int step = 1,
    String? nextName,
    bool alertAtRestEnd = false,
    bool force = false,
  }) => _serialize(() async {
    if (force) _lastShown = null;
    if (!_ready || _closed) return;
    try {
      final enabled = await _android?.areNotificationsEnabled() == true;
      if (!enabled) {
        await _plugin.cancel(id: _kNotifId);
        _lastShown = null;
        _status(NotificationLimitation.denied);
        return;
      }
      final now = DateTime.now();
      final view = workoutNotificationView(
        name: name,
        startedAt: startedAt,
        restStart: restStart,
        restTotal: restTotal,
        nextName: nextName,
        locale: locale,
      );
      final posted = workoutNotificationPayload(action, step, view);
      final mirror = RestMirror(
        view: view,
        payload: posted,
        actionable: action?.restStart != null,
        alertAtRestEnd: alertAtRestEnd,
        exact: await _android?.canScheduleExactNotifications() == true,
        now: now,
      );
      final payload = mirror.mode;
      final exact = mirror.exact;
      final alert = payload.countdown && alertAtRestEnd;
      final key =
          '$name|${payload.countdown}|${payload.when.toIso8601String()}|$posted|$exact|$locale|$alert|$nextName';
      if (key == _lastShown) return;
      _status(null);
      // The renderer cancels only the pending alarm; the mirror updates in place.
      await renderRestMirror(_plugin, mirror);
      _lastShown = key;
      if (action != null) {
        _trace?.call(
          'alkion-notif re-rendered ${action.token.length < 8 ? action.token : action.token.substring(0, 8)} $step',
        );
      }
    } catch (_) {
      _lastShown = null;
      _status(NotificationLimitation.unavailable);
      // A failed alarm must not leave a countdown running below zero forever.
      try {
        await postWorkoutMirror(
          _plugin,
          workoutNotificationView(
            name: name,
            startedAt: startedAt,
            nextName: nextName,
            locale: locale,
          ),
          countdown: false,
          when: startedAt,
          payload: action == null
              ? null
              : workoutNotificationPayload(action, step, null),
          actionable: action?.restStart != null,
        );
      } catch (_) {}
    }
  });

  bool get cancelOwed => _cancelOwed;
  bool _cancelOwed = false;
  Future<void> cancel() => _serialize(() async {
    _lastShown = null;
    if (!_ready) return;
    try {
      await _plugin.cancel(id: _kNotifId);
      _cancelOwed = false;
    } catch (_) {
      _cancelOwed = true;
      _status(NotificationLimitation.unavailable);
    }
  });

  Future<void> close() {
    _closed = true;
    return cancel();
  }
}

/// The payload the owner posts for [action]'s token: the envelope with the
/// next [step] and [view], fitted to [notificationPayloadByteLimit] UTF-8
/// bytes. Null without a token.
String? workoutNotificationPayload(
  NotificationAction? action,
  int step,
  NotificationView? view,
) => action == null
    ? null
    : NotificationEnvelope(
        action: action,
        step: step,
        view: view,
      ).encodeWithinBudget();
