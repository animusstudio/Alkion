import 'dart:io';
import 'dart:ui'; // PlatformDispatcher
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../identity/alkion_profile.dart';
import '../store/local_store.dart';
import '../store/schema.dart';
import '../domain/evidence.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Notification id and channel id. Top-level so both the instance and the
/// background isolate (which constructs a fresh plugin) agree on them.
const _kNotifId = 4101;
const _kChannelId = 'alkion.dev.workout_session';

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
            AndroidNotificationAction(
              'alkion.dev.add_30s',
              '+30s',
              showsUserInterface: true,
              cancelNotification: false,
            ),
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
Future<void> workoutNotificationBackground(
  NotificationResponse response,
) async {
  if (response.actionId != 'alkion.dev.add_30s' || response.payload == null) {
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final payload = jsonDecode(response.payload!) as Map;
    await extendRestInBackground(
      supportRoot: Directory(payload['root'] as String),
      expectedProfileId: payload['profile'] as String,
      generation: payload['generation'] as int,
      draftId: payload['draftId'] as String,
      restStart: payload['restStart'] as String,
    );
  } catch (_) {
    // Missing/stale payload, profile ownership held by foreground, or a failed
    // store leaves SQL untouched. No alternate preference/gate bypass exists.
  }
}

Future<void> extendRestInBackground({
  required Directory supportRoot,
  required String expectedProfileId,
  required int generation,
  required String draftId,
  required String restStart,
}) async {
  final profile = await AlkionProfile.open(supportRoot: supportRoot);
  if (profile.profileId != expectedProfileId) {
    throw const StoreException('foreign_profile');
  }
  final db = await LocalStore.open(
    profile: profile,
    expectedProfileId: expectedProfileId,
    schema: workflowSchemaRegistry(),
  );
  try {
    await db.writeTransaction((tx) async {
      if (tx.token.generation != generation) {
        throw const StoreException('stale_generation');
      }
      final row = await tx.localState(LocalStateKind.draft, 'active');
      final timer = await tx.localState(LocalStateKind.timer, 'active');
      if (row == null ||
          timer == null ||
          row['status'] != 'active' ||
          timer['status'] != 'active') {
        throw const StoreException('stale_local_state');
      }
      final draft = Map<String, Object?>.from(
        jsonDecode(utf8.decode((row['payload_bytes'] as List).cast<int>()))
            as Map,
      );
      final value = Map<String, Object?>.from(
        jsonDecode(utf8.decode((timer['payload_bytes'] as List).cast<int>()))
            as Map,
      );
      if (draft['draftId'] != draftId ||
          value['draftId'] != draftId ||
          value['restStart'] != restStart ||
          draft['restStart'] != restStart) {
        throw const StoreException('stale_rest');
      }
      final start = DateTime.parse(restStart),
          total = value['restTotal'] as int;
      if (!DateTime.now().isBefore(start.add(Duration(seconds: total)))) {
        throw const StoreException('expired_rest');
      }
      value['restTotal'] = total + 30;
      draft['restTotal'] = total + 30;
      await tx.putLocalState(
        LocalStateKind.draft,
        'active',
        localBytes(draft),
        expectedRevision: row['revision'] as int,
      );
      await tx.putLocalState(
        LocalStateKind.timer,
        'active',
        localBytes(value),
        expectedRevision: timer['revision'] as int,
      );
    });
  } finally {
    await db.close();
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
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _isAndroid = isAndroid ?? Platform.isAndroid;

  final FlutterLocalNotificationsPlugin _plugin;
  final bool _isAndroid;
  String? locale;
  bool _ready = false;
  bool _permissionAsked = false;
  ({String title, bool countdown, DateTime when})? _lastShown;
  DateTime? _lastScheduledEnd;

  Future<void> init({void Function()? onTap, void Function()? onAdd30}) async {
    if (!_isAndroid) {
      return;
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (resp) {
        if (resp.actionId == 'alkion.dev.add_30s') {
          onAdd30?.call();
        } else {
          onTap?.call();
        }
      },
      onDidReceiveBackgroundNotificationResponse: workoutNotificationBackground,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          AndroidNotificationChannel(
            _kChannelId,
            notifString(locale, 'channel'),
            importance: Importance.low,
            playSound: false,
          ),
        );
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
  }) => buildWorkoutAndroidDetails(
    countdown: countdown,
    when: when,
    withAction: withAction,
    channelName: channelName,
  );

  Future<void> showFor({
    required String name,
    required DateTime startedAt,
    DateTime? restStart,
    int restTotal = 0,
  }) async {
    if (!_ready) {
      return;
    }
    if (!_permissionAsked) {
      _permissionAsked = true;
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
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
    if (key == _lastShown) {
      return;
    } // unchanged → skip the re-show
    _lastShown = key;
    try {
      await _show(p, name, startedAt, restStart, restTotal);
    } catch (_) {
      if (_lastShown == key) {
        _lastShown = null;
      }
      rethrow;
    }
  }

  Future<void> _show(
    ({String title, String body, bool countdown, DateTime when}) p,
    String name,
    DateTime startedAt,
    DateTime? restStart,
    int restTotal,
  ) async {
    // The "+30s" action chip belongs only on the live rest countdown
    // (p.countdown true). Elapsed mode and the scheduled revert omit it.
    await _plugin.show(
      id: _kNotifId,
      title: p.title,
      body: notifString(locale, p.countdown ? 'rest' : 'inProgress'),
      notificationDetails: NotificationDetails(
        android: _androidDetails(
          countdown: p.countdown,
          when: p.when,
          withAction: p.countdown,
          channelName: notifString(locale, 'channel'),
        ),
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
          body: notifString(locale, 'inProgress'),
          scheduledDate: tz.TZDateTime.from(end, tz.UTC),
          notificationDetails: NotificationDetails(
            android: _androidDetails(
              countdown: false,
              when: startedAt,
              channelName: notifString(locale, 'channel'),
            ),
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
    if (!_ready) {
      return;
    }
    _lastShown = null;
    _lastScheduledEnd = null;
    try {
      await _plugin.cancel(id: _kNotifId);
      _cancelOwed = false;
    } catch (_) {
      _cancelOwed = true;
      rethrow;
    }
  }
}
