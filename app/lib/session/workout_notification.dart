import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../identity/alkion_identity.dart';
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

/// Android OS mirrors only. No callback opens a profile or writes SQL.
class WorkoutNotification extends ChangeNotifier {
  WorkoutNotification({
    @visibleForTesting FlutterLocalNotificationsPlugin? plugin,
    @visibleForTesting bool? isAndroid,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _isAndroid = isAndroid ?? Platform.isAndroid;

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
  Future<void> showFor({
    required String name,
    required DateTime startedAt,
    DateTime? restStart,
    int restTotal = 0,
    NotificationAction? action,
    String? nextName,
    bool alertAtRestEnd = false,
  }) => _serialize(() async {
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
      final mirror = RestMirror(
        view: workoutNotificationView(
          name: name,
          startedAt: startedAt,
          restStart: restStart,
          restTotal: restTotal,
          nextName: nextName,
          locale: locale,
        ),
        payload: action?.encode(),
        actionable: action?.restStart != null,
        alertAtRestEnd: alertAtRestEnd,
        exact: await _android?.canScheduleExactNotifications() == true,
        now: now,
      );
      final payload = mirror.mode;
      final exact = mirror.exact;
      final alert = payload.countdown && alertAtRestEnd;
      final key =
          '$name|${payload.countdown}|${payload.when.toIso8601String()}|${action?.encode()}|$exact|$locale|$alert|$nextName';
      if (key == _lastShown) return;
      _status(null);
      // The renderer removes a prior alarm and its displayed mirror first.
      await renderRestMirror(_plugin, mirror);
      _lastShown = key;
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
          payload: action?.encode(),
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
