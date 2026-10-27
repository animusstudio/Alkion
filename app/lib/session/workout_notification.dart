import 'dart:io';
import 'dart:ui'; // PlatformDispatcher

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../identity/alkion_identity.dart';
import 'notification_action.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Package-scoped notification identifiers for the selected runtime.
const _kNotifId = 4101;
final _kChannelId = AlkionIdentity.notificationChannel;

// Notification body strings keyed by locale. The notification is built with no
// BuildContext, so
// AppLocalizations is unreachable — this standalone map fills that gap.
const _notifStrings = <String, Map<String, String>>{
  'en': {
    'rest': 'Rest',
    'inProgress': 'Workout in progress',
    'channel': 'Workout session',
  },
  'it': {
    'rest': 'Recupero',
    'inProgress': 'Allenamento in corso',
    'channel': 'Sessione di allenamento',
  },
  'de': {
    'rest': 'Pause',
    'inProgress': 'Training läuft',
    'channel': 'Trainingssitzung',
  },
  'es': {
    'rest': 'Descanso',
    'inProgress': 'Entrenamiento en curso',
    'channel': 'Sesión de entrenamiento',
  },
};

/// Resolves a notification string for the active locale WITHOUT a BuildContext
/// Order: persisted override → platform locale → en.
String notifString(String? locale, String key) {
  final code = locale ?? PlatformDispatcher.instance.locale.languageCode;
  final table = _notifStrings[code] ?? _notifStrings['en']!;
  return table[key] ?? _notifStrings['en']![key]!;
}

/// Pure payload mapping for the ongoing workout notification (testable, no
/// plugin types). Elapsed mode: `when` = session start, Android chronometer
/// counts up. Rest mode: `when` = rest END time, chronometer counts down.
({String title, String body, bool countdown, DateTime when})
notificationPayloadFor({
  required String sessionName,
  required DateTime startedAt,
  DateTime? restStart,
  int restTotal = 0,
  required DateTime now,
}) {
  if (restStart != null) {
    final end = restStart.add(Duration(seconds: restTotal));
    if (end.isAfter(now)) {
      return (title: sessionName, body: 'Rest', countdown: true, when: end);
    }
  }
  return (
    title: sessionName,
    body: 'Workout in progress',
    countdown: false,
    when: startedAt,
  );
}

/// Absolute instant the rest countdown ends (used to schedule the OS-alarm
/// revert back to elapsed mode).
DateTime restRevertAt(DateTime restStart, int restTotal) =>
    restStart.add(Duration(seconds: restTotal));

/// Builds the Android details for the ongoing notification. Shared by both the
/// runtime mirror. [countdown] chooses chronometer
/// direction (true = rest countdown, false = elapsed); [when] anchors the
/// chronometer (rest end for countdown, session start for elapsed);
/// [withAction] adds the "+30s" action chip (only on the live rest countdown);
/// [channelName] is the localized channel display name (resolved by the caller,
/// which has the SharedPreferences this builder lacks).
AndroidNotificationDetails buildWorkoutAndroidDetails({
  required bool countdown,
  required DateTime when,
  required bool withAction,
  required String channelName,
}) {
  return AndroidNotificationDetails(
    _kChannelId,
    channelName,
    importance: Importance.low,
    priority: Priority.low,
    playSound: false,
    ongoing: true,
    autoCancel: false,
    onlyAlertOnce: true,
    showWhen: true,
    usesChronometer: true,
    chronometerCountDown: countdown,
    when: when.millisecondsSinceEpoch,
    category: AndroidNotificationCategory.stopwatch,
    actions: withAction
        ? <AndroidNotificationAction>[
            AndroidNotificationAction(
              AlkionIdentity.addRestAction,
              '+30s',
              showsUserInterface: true,
              cancelNotification: false,
            ),
          ]
        : null,
  );
}

enum NotificationLimitation { denied, inexact, unavailable }

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
  bool _ready = false, _closed = false, _permissionAsked = false;
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
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
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

  Future<void> showFor({
    required String name,
    required DateTime startedAt,
    DateTime? restStart,
    int restTotal = 0,
    NotificationAction? action,
  }) => _serialize(() async {
    if (!_ready || _closed) return;
    try {
      var enabled = await _android?.areNotificationsEnabled() == true;
      if (!enabled && !_permissionAsked) {
        _permissionAsked = true;
        enabled = await _android?.requestNotificationsPermission() == true;
      }
      if (!enabled) {
        await _plugin.cancel(id: _kNotifId);
        _lastShown = null;
        _status(NotificationLimitation.denied);
        return;
      }
      final payload = notificationPayloadFor(
        sessionName: name,
        startedAt: startedAt,
        restStart: restStart,
        restTotal: restTotal,
        now: DateTime.now(),
      );
      final exact = await _android?.canScheduleExactNotifications() == true;
      final key =
          '$name|${payload.countdown}|${payload.when.toIso8601String()}|${action?.encode()}|$exact|$locale';
      if (key == _lastShown) return;
      _status(
        payload.countdown && !exact ? NotificationLimitation.inexact : null,
      );
      // Remove a prior alarm as well as its displayed mirror before replacing it.
      await _plugin.cancel(id: _kNotifId);
      await _show(name, startedAt, payload.countdown, payload.when, action);
      if (payload.countdown) {
        Future<void> schedule(AndroidScheduleMode mode) =>
            _plugin.zonedSchedule(
              id: _kNotifId,
              title: name,
              body: notifString(locale, 'inProgress'),
              scheduledDate: tz.TZDateTime.from(payload.when, tz.UTC),
              notificationDetails: NotificationDetails(
                android: buildWorkoutAndroidDetails(
                  countdown: false,
                  when: startedAt,
                  withAction: false,
                  channelName: notifString(locale, 'channel'),
                ),
              ),
              payload: action?.encode(),
              androidScheduleMode: mode,
            );
        try {
          await schedule(
            exact
                ? AndroidScheduleMode.exactAllowWhileIdle
                : AndroidScheduleMode.inexactAllowWhileIdle,
          );
        } catch (_) {
          if (!exact) rethrow;
          _status(NotificationLimitation.inexact);
          await schedule(AndroidScheduleMode.inexactAllowWhileIdle);
        }
      }
      _lastShown = key;
    } catch (_) {
      _lastShown = null;
      _status(NotificationLimitation.unavailable);
      // A failed alarm must not leave a countdown running below zero forever.
      try {
        await _show(name, startedAt, false, startedAt, action);
      } catch (_) {}
    }
  });

  Future<void> _show(
    String name,
    DateTime startedAt,
    bool countdown,
    DateTime when,
    NotificationAction? action,
  ) => _plugin.show(
    id: _kNotifId,
    title: name,
    body: notifString(locale, countdown ? 'rest' : 'inProgress'),
    payload: action?.encode(),
    notificationDetails: NotificationDetails(
      android: buildWorkoutAndroidDetails(
        countdown: countdown,
        when: when,
        withAction: countdown && action?.restStart != null,
        channelName: notifString(locale, 'channel'),
      ),
    ),
  );

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
