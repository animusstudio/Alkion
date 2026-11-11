import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/session/workout_notification_render.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  test('the owner view carries the bodies the mirror showed before', () {
    for (final locale in ['en', 'de', 'es', 'it']) {
      final view = workoutNotificationView(
        name: 'Synthetic',
        startedAt: DateTime.utc(2026, 6, 3, 10),
        nextName: 'Row',
        locale: locale,
      );
      expect(view.title, 'Synthetic');
      expect(view.restBody, notificationNextBody(locale, 'Row', 'x'));
      expect(view.elapsedBody, view.restBody);
      expect(view.locale, locale);
      final idle = workoutNotificationView(
        name: 'Synthetic',
        startedAt: DateTime.utc(2026, 6, 3, 10),
        locale: locale,
      );
      expect(idle.restBody, notifString(locale, 'rest'));
      expect(idle.elapsedBody, 'Synthetic');
    }
  });

  test('the owner view stores the resolved locale, never null', () {
    final platform = notificationLocale(null);
    expect(platform, isNotEmpty);
    final view = workoutNotificationView(
      name: 'Synthetic',
      startedAt: DateTime.utc(2026, 6, 3, 10),
      nextName: 'Row',
    );
    expect(view.locale, platform);
    expect(view.restBody, notificationNextBody(platform, 'Row', 'x'));
    expect(
      workoutNotificationView(
        name: 'Synthetic',
        startedAt: DateTime.utc(2026, 6, 3, 10),
        locale: 'it',
      ).locale,
      'it',
    );
    expect(notificationLocale('de'), 'de');
  });

  test('+30s holds the fixed first action index', () {
    expect(addRestActionIndex, 0);
    final actions = workoutNotificationActions();
    expect(actions[addRestActionIndex].id, AlkionIdentity.addRestAction);
    expect(actions[addRestActionIndex].title, '+30s');
    expect(actions[addRestActionIndex].cancelNotification, isFalse);
  });

  group('renderRestMirror over the plugin v21 method channel', () {
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    late List<MethodCall> calls;
    late bool failExact;
    late FlutterLocalNotificationsPlugin plugin;
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      calls = [];
      failExact = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'zonedSchedule' &&
                failExact &&
                (call.arguments as Map)['platformSpecifics']['scheduleMode'] ==
                    AndroidScheduleMode.exactAllowWhileIdle.name) {
              throw PlatformException(code: 'exact_alarms_not_permitted');
            }
            return null;
          });
      plugin = FlutterLocalNotificationsPlugin();
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    RestMirror mirror({
      DateTime? restStart,
      int restTotal = 600,
      bool alert = false,
      bool exact = true,
      bool actionable = true,
      String? locale = 'en',
      String? payload = 'synthetic-payload',
    }) {
      final now = DateTime.now();
      return RestMirror(
        view: workoutNotificationView(
          name: 'Synthetic',
          startedAt: now.subtract(const Duration(minutes: 5)),
          restStart: restStart,
          restTotal: restTotal,
          nextName: 'Bench Press',
          locale: locale,
        ),
        payload: payload,
        actionable: actionable,
        alertAtRestEnd: alert,
        exact: exact,
        now: now,
      );
    }

    Map<dynamic, dynamic> args(String method) =>
        calls.singleWhere((c) => c.method == method).arguments as Map;

    test(
      'a countdown cancels, posts with the actions, then schedules',
      () async {
        final state = mirror(restStart: DateTime.now(), alert: true);
        await renderRestMirror(plugin, state);
        expect(calls.map((c) => c.method), ['cancel', 'show', 'zonedSchedule']);
        expect(args('cancel')['id'], workoutNotificationId);
        final shown = args('show');
        expect(shown['id'], workoutNotificationId);
        expect(shown['title'], 'Synthetic');
        expect(shown['body'], 'Next · Bench Press');
        expect(shown['payload'], 'synthetic-payload');
        final details = shown['platformSpecifics'] as Map;
        expect(details['channelId'], AlkionIdentity.notificationChannel);
        expect(details['chronometerCountDown'], isTrue);
        expect(details['when'], state.mode.when.millisecondsSinceEpoch);
        final actions = details['actions'] as List;
        expect(actions[addRestActionIndex]['id'], AlkionIdentity.addRestAction);
        final scheduled = args('zonedSchedule');
        expect(scheduled['id'], workoutNotificationId);
        expect(scheduled['title'], 'Rest finished');
        expect(scheduled['body'], 'Next · Bench Press');
        expect(scheduled['payload'], 'synthetic-payload');
        expect(
          scheduled['platformSpecifics']['channelId'],
          AlkionIdentity.restEndChannel,
        );
        expect(
          scheduled['platformSpecifics']['scheduleMode'],
          AndroidScheduleMode.exactAllowWhileIdle.name,
        );
      },
    );

    test('the quiet variant schedules the elapsed mirror', () async {
      await renderRestMirror(
        plugin,
        mirror(restStart: DateTime.now(), locale: 'de'),
      );
      final scheduled = args('zonedSchedule');
      expect(scheduled['title'], 'Synthetic');
      expect(scheduled['body'], 'Training läuft');
      final details = scheduled['platformSpecifics'] as Map;
      expect(details['channelId'], AlkionIdentity.notificationChannel);
      expect(details['chronometerCountDown'], isFalse);
      expect(details['actions'], isNull);
      expect(args('show')['body'], 'Als Nächstes · Bench Press');
    });

    test('elapsed mode posts no actions and schedules nothing', () async {
      for (final state in [
        mirror(),
        mirror(
          restStart: DateTime.now().subtract(const Duration(minutes: 20)),
          alert: true,
        ),
      ]) {
        calls.clear();
        await renderRestMirror(plugin, state);
        expect(calls.map((c) => c.method), ['cancel', 'show']);
        final shown = args('show');
        expect(shown['body'], 'Workout in progress');
        final details = shown['platformSpecifics'] as Map;
        expect(details['chronometerCountDown'], isFalse);
        expect(details['actions'], isNull);
        expect(details['when'], state.view.startedAt.millisecondsSinceEpoch);
      }
    });

    test('a countdown without an action posts no actions', () async {
      await renderRestMirror(
        plugin,
        mirror(restStart: DateTime.now(), actionable: false, payload: null),
      );
      final shown = args('show');
      expect(
        shown['payload'],
        '',
        reason: 'the plugin sends no payload as empty',
      );
      expect(shown['platformSpecifics']['actions'], isNull);
    });

    test('exact refusal falls back to an inexact schedule', () async {
      failExact = true;
      await renderRestMirror(plugin, mirror(restStart: DateTime.now()));
      final modes = [
        for (final c in calls.where((c) => c.method == 'zonedSchedule'))
          (c.arguments as Map)['platformSpecifics']['scheduleMode'],
      ];
      expect(modes, [
        AndroidScheduleMode.exactAllowWhileIdle.name,
        AndroidScheduleMode.inexactAllowWhileIdle.name,
      ]);
    });

    test('the renderer never initializes, queries or prompts', () async {
      await renderRestMirror(
        plugin,
        mirror(restStart: DateTime.now(), alert: true, exact: false),
      );
      expect(calls.map((c) => c.method).toSet(), {
        'cancel',
        'show',
        'zonedSchedule',
      });
    });
  });
}
