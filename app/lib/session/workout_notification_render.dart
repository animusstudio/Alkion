import 'dart:ui'; // PlatformDispatcher

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../identity/alkion_identity.dart';
import 'notification_envelope.dart';

/// The pure workout-notification renderer. Shared by the SQL owner
/// (`workout_notification.dart`) and, later, the background handler, so it
/// imports no store, SQL or Flutter UI code
/// (`test/session/notification_import_guard_test.dart`).
///
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
/// - [AlkionIdentity.addRestAction] (`<prefix>add_30s`) and
///   [AlkionIdentity.skipRestAction] (`<prefix>skip_rest`): the +30s and Skip
///   rest actions on the rest countdown. Both are background actions: the
///   plugin's `ActionBroadcastReceiver` hands them to the headless messenger
///   (`notification_background.dart`), which journals them; the app never
///   comes forward.
const workoutNotificationId = 4101;

/// Fixed action order. A tap delivers the payload last posted for its action
/// *index* (the plugin's request code is `id * 16 + index`), so an action
/// never moves to another index between renders: +30s is always index 0 and
/// Skip rest index 1.
const addRestActionIndex = 0;
const skipRestActionIndex = 1;

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
    'skipRest': 'Skip rest',
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
    'skipRest': 'Salta recupero',
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
    'skipRest': 'Pause überspringen',
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
    'skipRest': 'Saltar descanso',
    'restEndChannelDescription':
        'Aviso con vibración cuando termina un descanso y el entrenamiento no está en pantalla.',
  },
};

/// The language code notification strings use: the persisted override, else
/// the platform locale's.
String notificationLocale(String? locale) =>
    locale ?? PlatformDispatcher.instance.locale.languageCode;

/// Resolves a notification string for the active locale WITHOUT a BuildContext
/// Order: persisted override → platform locale → en.
String notifString(String? locale, String key) {
  final code = notificationLocale(locale);
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

/// The view the owner renders for a workout: the bodies carry the next-set
/// line, every label comes from the view's locale at render time. The locale
/// is resolved here, never stored as null, so a render in another engine
/// uses the owner's language.
NotificationView workoutNotificationView({
  required String name,
  required DateTime startedAt,
  DateTime? restStart,
  int restTotal = 0,
  String? nextName,
  String? locale,
}) {
  final code = notificationLocale(locale);
  return NotificationView(
    title: name,
    restBody: notificationNextBody(code, nextName, notifString(code, 'rest')),
    elapsedBody: notificationNextBody(code, nextName, name),
    startedAt: startedAt,
    restStart: restStart,
    restTotal: restTotal,
    locale: code,
  );
}

/// Pure payload mapping for the ongoing workout notification (testable, no
/// plugin types). Elapsed mode: `when` = session start, Android chronometer
/// counts up. Rest mode: `when` = rest END time, chronometer counts down.
/// The localized bodies are chosen by [renderRestMirror].
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

/// The rest countdown's actions, in the fixed order ([addRestActionIndex],
/// [skipRestActionIndex]). Neither shows the app: each is a broadcast to the
/// plugin's receiver, and neither dismisses the notification.
List<AndroidNotificationAction> workoutNotificationActions([String? locale]) =>
    <AndroidNotificationAction>[
      AndroidNotificationAction(
        AlkionIdentity.addRestAction,
        '+30s',
        showsUserInterface: false,
        cancelNotification: false,
      ),
      AndroidNotificationAction(
        AlkionIdentity.skipRestAction,
        notifString(locale, 'skipRest'),
        showsUserInterface: false,
        cancelNotification: false,
      ),
    ];

/// Builds the Android details for the ongoing notification. Shared by both the
/// runtime mirror. [countdown] chooses chronometer
/// direction (true = rest countdown, false = elapsed); [when] anchors the
/// chronometer (rest end for countdown, session start for elapsed);
/// [withAction] adds the +30s and Skip rest actions (only on the live rest
/// countdown), labelled for [locale];
/// [channelName] is the localized channel display name (resolved by the caller,
/// which has the SharedPreferences this builder lacks).
AndroidNotificationDetails buildWorkoutAndroidDetails({
  required bool countdown,
  required DateTime when,
  required bool withAction,
  required String channelName,
  String? locale,
}) {
  return AndroidNotificationDetails(
    AlkionIdentity.notificationChannel,
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
    actions: withAction ? workoutNotificationActions(locale) : null,
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
    AlkionIdentity.restEndChannel,
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

/// What one render posts. [payload] is posted exactly as given; [actionable]
/// allows the actions on a live countdown; [alertAtRestEnd] schedules the
/// rest-end alert variant instead of the quiet elapsed mirror; [exact] picks
/// the exact alarm mode (with an inexact fallback).
final class RestMirror {
  const RestMirror({
    required this.view,
    required this.payload,
    required this.actionable,
    required this.alertAtRestEnd,
    required this.exact,
    required this.now,
  });
  final NotificationView view;
  final String? payload;
  final bool actionable, alertAtRestEnd, exact;
  final DateTime now;

  ({String title, bool countdown, DateTime when}) get mode =>
      notificationPayloadFor(
        sessionName: view.title,
        startedAt: view.startedAt,
        restStart: view.restStart,
        restTotal: view.restTotal,
        now: now,
      );
}

/// Posts the workout mirror under [workoutNotificationId] in one mode.
Future<void> postWorkoutMirror(
  FlutterLocalNotificationsPlugin plugin,
  NotificationView view, {
  required bool countdown,
  required DateTime when,
  required String? payload,
  required bool actionable,
}) => plugin.show(
  id: workoutNotificationId,
  title: view.title,
  body: countdown ? view.restBody : notifString(view.locale, 'inProgress'),
  payload: payload,
  notificationDetails: NotificationDetails(
    android: buildWorkoutAndroidDetails(
      countdown: countdown,
      when: when,
      withAction: countdown && actionable,
      channelName: notifString(view.locale, 'channel'),
      locale: view.locale,
    ),
  ),
);

/// Posts the mirror and reschedules or cancels the rest-end post, and does
/// nothing else: no permission prompt, no initialization, no storage. The
/// prior post and its alarm are cancelled first (the plugin's cancel removes
/// both); a countdown then schedules the post that follows the rest.
Future<void> renderRestMirror(
  FlutterLocalNotificationsPlugin plugin,
  RestMirror state,
) async {
  final view = state.view, locale = view.locale;
  final mode = state.mode;
  final alert = mode.countdown && state.alertAtRestEnd;
  await plugin.cancel(id: workoutNotificationId);
  await postWorkoutMirror(
    plugin,
    view,
    countdown: mode.countdown,
    when: mode.when,
    payload: state.payload,
    actionable: state.actionable,
  );
  if (!mode.countdown) return;
  Future<void> schedule(AndroidScheduleMode scheduleMode) =>
      plugin.zonedSchedule(
        id: workoutNotificationId,
        title: alert ? notifString(locale, 'restEnd') : view.title,
        body: alert ? view.elapsedBody : notifString(locale, 'inProgress'),
        scheduledDate: tz.TZDateTime.from(mode.when, tz.UTC),
        notificationDetails: NotificationDetails(
          android: alert
              ? buildRestEndAndroidDetails(
                  startedAt: view.startedAt,
                  channelName: notifString(locale, 'restEndChannel'),
                  channelDescription: notifString(
                    locale,
                    'restEndChannelDescription',
                  ),
                )
              : buildWorkoutAndroidDetails(
                  countdown: false,
                  when: view.startedAt,
                  withAction: false,
                  channelName: notifString(locale, 'channel'),
                ),
        ),
        payload: state.payload,
        androidScheduleMode: scheduleMode,
      );
  try {
    await schedule(
      state.exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
    );
  } catch (_) {
    if (!state.exact) rethrow;
    await schedule(AndroidScheduleMode.inexactAllowWhileIdle);
  }
}
