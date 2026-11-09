import 'dart:io';
import 'dart:ui'; // PlatformDispatcher

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../identity/alkion_identity.dart';
import 'notification_action.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Notification identifiers. Keep them stable: Android keys user channel
/// settings by channel id, and later notification actions build on them.
///
/// - Notification id 4101: the single workout notification. The elapsed
///   mirror, the rest countdown and the scheduled rest-end post all use it,
///   so each one replaces the previous.
/// - [AlkionIdentity.notificationChannel] (`<prefix>workout_session`): the
///   quiet mirror channel, low importance, no sound.
/// - [AlkionIdentity.restEndChannel] (`<prefix>rest_end`): the rest-end
///   alert, high importance (heads-up), vibration, no sound. The user tunes
///   or silences it in Android settings; the app has no switch for it.
/// - [AlkionIdentity.addRestAction] (`<prefix>add_30s`): the +30s action on
///   the rest countdown.
const _kNotifId = 4101;
final _kChannelId = AlkionIdentity.notificationChannel;
final _kRestEndChannelId = AlkionIdentity.restEndChannel;

/// The status-bar glyph: a monochrome vector in the Android drawables.
const kNotificationSmallIcon = '@drawable/ic_stat_alkion';

// Notification body strings keyed by locale. The notification is built with no
// BuildContext, so
// AppLocalizations is unreachable — this standalone map fills that gap.
const _notifStrings = <String, Map<String, String>>{
  'en': {
    'rest': 'Rest',
    'inProgress': 'Workout in progress',
    'channel': 'Workout session',
    'next': 'Next · {name}',
    'restEnd': 'Rest finished',
    'restEndChannel': 'Rest end',
    'restEndChannelDescription':
        'Heads-up with vibration when a rest ends while the workout is not on screen.',
  },
  'it': {
    'rest': 'Recupero',
    'inProgress': 'Allenamento in corso',
    'channel': 'Sessione di allenamento',
    'next': 'Dopo · {name}',
    'restEnd': 'Recupero finito',
    'restEndChannel': 'Fine del recupero',
    'restEndChannelDescription':
        "Avviso con vibrazione quando un recupero finisce mentre l'allenamento non è sullo schermo.",
  },
  'de': {
    'rest': 'Pause',
    'inProgress': 'Training läuft',
    'channel': 'Trainingssitzung',
    'next': 'Als Nächstes · {name}',
    'restEnd': 'Pause vorbei',
    'restEndChannel': 'Pausenende',
    'restEndChannelDescription':
        'Hinweis mit Vibration, wenn eine Pause endet, während das Training nicht angezeigt wird.',
  },
  'es': {
    'rest': 'Descanso',
    'inProgress': 'Entrenamiento en curso',
    'channel': 'Sesión de entrenamiento',
    'next': 'Siguiente · {name}',
    'restEnd': 'Descanso terminado',
    'restEndChannel': 'Fin del descanso',
    'restEndChannelDescription':
        'Aviso con vibración cuando termina un descanso y el entrenamiento no está en pantalla.',
  },
};

/// Resolves a notification string for the active locale WITHOUT a BuildContext
/// Order: persisted override → platform locale → en.
String notifString(String? locale, String key) {
  final code = locale ?? PlatformDispatcher.instance.locale.languageCode;
  final table = _notifStrings[code] ?? _notifStrings['en']!;
  return table[key] ?? _notifStrings['en']![key]!;
}

/// "Next · name" for the next pending exercise, or [fallback] when nothing
/// is pending. Names only: no weights or reps, so no unit formatting.
String notificationNextBody(String? locale, String? nextName, String fallback) {
  final name = nextName?.trim();
  if (name == null || name.isEmpty) return fallback;
  return notifString(locale, 'next').replaceFirst('{name}', name);
}

/// Pure payload mapping for the ongoing workout notification (testable, no
/// plugin types). Elapsed mode: `when` = session start, Android chronometer
/// counts up. Rest mode: `when` = rest END time, chronometer counts down.
/// The localized bodies are chosen by [WorkoutNotification].
({String title, bool countdown, DateTime when}) notificationPayloadFor({
  required String sessionName,
  required DateTime startedAt,
  DateTime? restStart,
  int restTotal = 0,
  required DateTime now,
}) {
  if (restStart != null) {
    final end = restStart.add(Duration(seconds: restTotal));
    if (end.isAfter(now)) {
      return (title: sessionName, countdown: true, when: end);
    }
  }
  return (title: sessionName, countdown: false, when: startedAt);
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

/// The rest-end alert, posted at the end of a rest when the workout screen is
/// not in front of the user. It replaces the mirror under the same id, so it
/// stays ongoing and keeps the elapsed chronometer; unlike the mirror it may
/// alert (no `onlyAlertOnce`), on the high-importance vibrating channel.
AndroidNotificationDetails buildRestEndAndroidDetails({
  required DateTime startedAt,
  required String channelName,
  String? channelDescription,
}) {
  return AndroidNotificationDetails(
    _kRestEndChannelId,
    channelName,
    channelDescription: channelDescription,
    importance: Importance.high,
    priority: Priority.high,
    playSound: false,
    enableVibration: true,
    ongoing: true,
    autoCancel: false,
    onlyAlertOnce: false,
    showWhen: true,
    usesChronometer: true,
    chronometerCountDown: false,
    when: startedAt.millisecondsSinceEpoch,
    category: AndroidNotificationCategory.stopwatch,
  );
}

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
      final payload = notificationPayloadFor(
        sessionName: name,
        startedAt: startedAt,
        restStart: restStart,
        restTotal: restTotal,
        now: DateTime.now(),
      );
      final exact = await _android?.canScheduleExactNotifications() == true;
      final alert = payload.countdown && alertAtRestEnd;
      final key =
          '$name|${payload.countdown}|${payload.when.toIso8601String()}|${action?.encode()}|$exact|$locale|$alert|$nextName';
      if (key == _lastShown) return;
      _status(null);
      // Remove a prior alarm as well as its displayed mirror before replacing it.
      await _plugin.cancel(id: _kNotifId);
      await _show(
        name,
        startedAt,
        payload.countdown,
        payload.when,
        action,
        nextName,
      );
      if (payload.countdown) {
        Future<void> schedule(AndroidScheduleMode mode) =>
            _plugin.zonedSchedule(
              id: _kNotifId,
              title: alert ? notifString(locale, 'restEnd') : name,
              body: alert
                  ? notificationNextBody(locale, nextName, name)
                  : notifString(locale, 'inProgress'),
              scheduledDate: tz.TZDateTime.from(payload.when, tz.UTC),
              notificationDetails: NotificationDetails(
                android: alert
                    ? buildRestEndAndroidDetails(
                        startedAt: startedAt,
                        channelName: notifString(locale, 'restEndChannel'),
                        channelDescription: notifString(
                          locale,
                          'restEndChannelDescription',
                        ),
                      )
                    : buildWorkoutAndroidDetails(
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
          await schedule(AndroidScheduleMode.inexactAllowWhileIdle);
        }
      }
      _lastShown = key;
    } catch (_) {
      _lastShown = null;
      _status(NotificationLimitation.unavailable);
      // A failed alarm must not leave a countdown running below zero forever.
      try {
        await _show(name, startedAt, false, startedAt, action, nextName);
      } catch (_) {}
    }
  });

  Future<void> _show(
    String name,
    DateTime startedAt,
    bool countdown,
    DateTime when,
    NotificationAction? action,
    String? nextName,
  ) => _plugin.show(
    id: _kNotifId,
    title: name,
    body: countdown
        ? notificationNextBody(locale, nextName, notifString(locale, 'rest'))
        : notifString(locale, 'inProgress'),
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
