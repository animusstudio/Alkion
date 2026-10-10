import 'dart:io';
import 'dart:ui'; // PlatformDispatcher

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../capture/capture_startup.dart' show CaptureLocations;
import '../capture/session_capture_hooks.dart' show SessionWriteLedger;
import '../capture/source_write_gate.dart';

/// Notification id and channel id. Top-level so both the instance and the
/// background isolate (which constructs a fresh plugin) agree on them.
const _kNotifId = 1;
const _kChannelId = 'workout_session';

// Rest-state blob keys (written on rest, read by the background +30s handler
// and by SessionManager's foreground reconciliation).
const restBlobName = 'rest.name';
const restBlobStartedAt = 'rest.started_at'; // iso8601
const restBlobStartMs = 'rest.start_ms'; // epoch millis of restStart
const restBlobTotal = 'rest.total'; // seconds

// Notification body strings keyed by locale. The notification is built with no
// BuildContext (and the +30s revert path runs in a background isolate), so
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
/// (works in the background isolate). Order: persisted override → platform
/// locale → en. [prefs] is the already-loaded SharedPreferences.
String notifString(SharedPreferences prefs, String key) {
  final code = prefs.getString('settings.locale') ??
      PlatformDispatcher.instance.locale.languageCode;
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
/// instance and the background isolate. [countdown] chooses chronometer
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
        ? const <AndroidNotificationAction>[
            AndroidNotificationAction('add_30s', '+30s',
                showsUserInterface: false, cancelNotification: false),
          ]
        : null,
  );
}

/// Background-isolate handler for the +30s action when the app is killed.
/// Reads the rest blob, extends it by 30s, rewrites it, and reschedules both
/// the live countdown and the OS revert alarm — without the live controller.
///
/// Runs in a fresh isolate, so it must initialize the binding, timezones, and
/// a brand-new plugin instance before scheduling. Compiles on all platforms
/// (referenced by name in [WorkoutNotification.init]) but only fires on Android.
@pragma('vm:entry-point')
Future<void> workoutNotificationBackground(NotificationResponse resp) async {
  if (resp.actionId != 'add_30s') return;
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  // This engine's own instance of the shared source gate: every engine's
  // admission goes through the one native ticket table and lock.
  final appSupport = await getApplicationSupportDirectory();
  await extendRestInBackground(
      gate: SourceWriteGate(stateDirectory: CaptureLocations(appSupport).gate));
}

/// The background +30s, as one admitted source operation of [gate] (this
/// engine's instance; null runs ungated, as on a build without the capture
/// plugin, where [SourceWriteGate.run] also runs ungated).
///
/// The ticket is taken BEFORE preferences are loaded or reloaded and is held
/// through every preference write and plugin call, so a data capture either
/// waits for the whole extension or refuses it before anything is read.
/// While a capture has admission closed the tap changes nothing: the rest
/// keeps its earlier end (the extension is unavailable during capture).
Future<void> extendRestInBackground({
  required SourceWriteGate? gate,
  FlutterLocalNotificationsPlugin? plugin,
}) async {
  Future<void> body(SourceTicket _) =>
      _extendRest(plugin ?? FlutterLocalNotificationsPlugin());
  try {
    if (gate == null) {
      await body(SourceTicket.ungated);
    } else {
      await gate.run('notification.background_add30', body);
    }
  } on SourceGateException {
    // Refused while a capture holds the source, or the gate failed: nothing
    // was read or written.
  }
}

Future<void> _extendRest(FlutterLocalNotificationsPlugin plugin) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload(); // refresh in case the isolate/engine is reused across taps
  final startMs = prefs.getInt(restBlobStartMs);
  final total = prefs.getInt(restBlobTotal);
  final name = prefs.getString(restBlobName);
  final startedAtIso = prefs.getString(restBlobStartedAt);
  if (startMs == null ||
      total == null ||
      name == null ||
      startedAtIso == null) {
    return;
  }
  final newTotal = total + 30;
  await prefs.setInt(restBlobTotal, newTotal);
  final restStart = DateTime.fromMillisecondsSinceEpoch(startMs);
  final startedAt = DateTime.parse(startedAtIso);
  final end = restStart.add(Duration(seconds: newTotal));

  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  await plugin.show(
    id: _kNotifId,
    title: name,
    body: notifString(prefs, 'rest'),
    notificationDetails: NotificationDetails(
      android: buildWorkoutAndroidDetails(
          countdown: true,
          when: end,
          withAction: true,
          channelName: notifString(prefs, 'channel')),
    ),
  );
  if (end.isAfter(DateTime.now())) {
    await plugin.zonedSchedule(
      id: _kNotifId,
      title: name,
      body: notifString(prefs, 'inProgress'),
      scheduledDate: tz.TZDateTime.from(end, tz.UTC),
      notificationDetails: NotificationDetails(
        android: buildWorkoutAndroidDetails(
            countdown: false,
            when: startedAt,
            withAction: false,
            channelName: notifString(prefs, 'channel')),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }
}

/// Thin Android-only wrapper around flutter_local_notifications. All methods
/// are no-ops off-Android (Linux dev builds never initialize the plugin).
///
/// Writing the rest blob and updating the notification is one admitted
/// source operation per call. While a data capture holds the source the
/// call changes nothing and remembers nothing as shown, so the next call
/// after the capture (see [SessionManager.resumeCallbacks]) writes it.
class WorkoutNotification {
  WorkoutNotification({
    @visibleForTesting FlutterLocalNotificationsPlugin? plugin,
    @visibleForTesting bool? isAndroid,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _isAndroid = isAndroid ?? Platform.isAndroid;

  final FlutterLocalNotificationsPlugin _plugin;
  final bool _isAndroid;
  bool _ready = false;
  bool _permissionAsked = false;
  ({String title, bool countdown, DateTime when})? _lastShown;
  DateTime? _lastScheduledEnd;

  Future<void> init({void Function()? onTap, void Function()? onAdd30}) async {
    if (!_isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (resp) {
        if (resp.actionId == 'add_30s') {
          onAdd30?.call();
        } else {
          onTap?.call();
        }
      },
      onDidReceiveBackgroundNotificationResponse: workoutNotificationBackground,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(AndroidNotificationChannel(
          _kChannelId,
          notifString(prefs, 'channel'),
          importance: Importance.low,
          playSound: false,
        ));
    tzdata.initializeTimeZones();
    _ready = true;
  }

  /// Builds the Android details for the ongoing notification, delegating to the
  /// top-level [buildWorkoutAndroidDetails] shared with the background isolate.
  AndroidNotificationDetails _androidDetails({
    required bool countdown,
    required DateTime when,
    required String channelName,
    bool withAction = false,
  }) =>
      buildWorkoutAndroidDetails(
          countdown: countdown,
          when: when,
          withAction: withAction,
          channelName: channelName);

  Future<void> showFor({
    required String name,
    required DateTime startedAt,
    DateTime? restStart,
    int restTotal = 0,
  }) async {
    if (!_ready) return;
    if (!_permissionAsked) {
      _permissionAsked = true;
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission(); // result ignored — degrades silently
    }
    final p = notificationPayloadFor(
      sessionName: name,
      startedAt: startedAt,
      restStart: restStart,
      restTotal: restTotal,
      now: DateTime.now(),
    );
    final key = (title: p.title, countdown: p.countdown, when: p.when);
    if (key == _lastShown) return; // unchanged → skip the re-show
    _lastShown = key;
    try {
      await runSourceWrite('notification.show',
          (_) => _show(p, name, startedAt, restStart, restTotal));
    } on SourceGateException {
      // Refused (a data capture holds the source): nothing was written or
      // shown; forget the key so the next call shows it.
      if (_lastShown == key) _lastShown = null;
    }
  }

  Future<void> _show(
    ({String title, String body, bool countdown, DateTime when}) p,
    String name,
    DateTime startedAt,
    DateTime? restStart,
    int restTotal,
  ) async {
    // Persist/clear the rest blob (read by the background +30s handler and the
    // foreground reconciliation). The blob mirrors the live rest state.
    final prefs = await SharedPreferences.getInstance();
    await SessionWriteLedger.instance.write('prefs.rest_blob', () async {
      if (restStart != null) {
        await prefs.setString(restBlobName, name);
        await prefs.setString(restBlobStartedAt, startedAt.toIso8601String());
        await prefs.setInt(restBlobStartMs, restStart.millisecondsSinceEpoch);
        await prefs.setInt(restBlobTotal, restTotal);
      } else {
        await _removeRestBlob(prefs);
      }
    });
    // The "+30s" action chip belongs only on the live rest countdown
    // (p.countdown true). Elapsed mode and the scheduled revert omit it.
    await _plugin.show(
      id: _kNotifId,
      title: p.title,
      body: notifString(prefs, p.countdown ? 'rest' : 'inProgress'),
      notificationDetails: NotificationDetails(
        android: _androidDetails(
            countdown: p.countdown,
            when: p.when,
            withAction: p.countdown,
            channelName: notifString(prefs, 'channel')),
      ),
    );
    // Schedule the OS alarm that reverts the countdown back to elapsed mode at
    // rest end — Dart timers are suspended while backgrounded, so without this
    // the chronometer counts into negatives. The scheduled notification reuses
    // id=_kNotifId, so the OS REPLACES the live countdown at restEnd.
    // Re-scheduling id=_kNotifId replaces any prior alarm.
    final end = restStart == null ? null : restRevertAt(restStart, restTotal);
    if (end != null && end.isAfter(DateTime.now())) {
      if (_lastScheduledEnd != end) {
        _lastScheduledEnd = end;
        await _plugin.zonedSchedule(
          id: _kNotifId,
          title: name,
          body: notifString(prefs, 'inProgress'),
          scheduledDate: tz.TZDateTime.from(end, tz.UTC),
          notificationDetails: NotificationDetails(
            android: _androidDetails(
                countdown: false,
                when: startedAt,
                channelName: notifString(prefs, 'channel')),
          ),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
      }
    }
  }

  /// Whether the last [cancel] was refused (a data capture held the source)
  /// and still has to run.
  bool get cancelOwed => _cancelOwed;
  bool _cancelOwed = false;

  Future<void> cancel() async {
    if (!_ready) return;
    _lastShown = null;
    _lastScheduledEnd = null;
    try {
      await runSourceWrite('notification.cancel', (_) async {
        final prefs = await SharedPreferences.getInstance();
        await SessionWriteLedger.instance
            .write('prefs.rest_blob', () => _removeRestBlob(prefs));
        await _plugin.cancel(id: _kNotifId); // cancels the shown notification AND the pending alarm
      });
      _cancelOwed = false;
    } on SourceGateException {
      // Refused while a data capture holds the source: the blob and the
      // notification stay until the cancel runs after the capture.
      _cancelOwed = true;
    }
  }

  static Future<void> _removeRestBlob(SharedPreferences prefs) async {
    await prefs.remove(restBlobName);
    await prefs.remove(restBlobStartedAt);
    await prefs.remove(restBlobStartMs);
    await prefs.remove(restBlobTotal);
  }
}
