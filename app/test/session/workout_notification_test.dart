import 'package:flutter_test/flutter_test.dart';
import 'dart:ui' show PluginUtilities;

import 'package:alkion/session/notification_background.dart'
    show onBackgroundNotificationResponse;
import 'package:alkion/session/notification_envelope.dart';
import 'package:alkion/session/workout_notification.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final started = DateTime(2026, 6, 3, 10, 0);
  final now = DateTime(2026, 6, 3, 10, 30);

  test('elapsed mode when not resting', () {
    final p = notificationPayloadFor(
      sessionName: 'Upper A',
      startedAt: started,
      now: now,
    );
    expect(p.title, 'Upper A');
    expect(p.countdown, isFalse);
    expect(p.when, started);
  });

  test('countdown mode while resting, when = rest end', () {
    final restStart = DateTime(2026, 6, 3, 10, 29, 30);
    final p = notificationPayloadFor(
      sessionName: 'Upper A',
      startedAt: started,
      restStart: restStart,
      restTotal: 90,
      now: now, // 30s in, 60s remaining
    );
    expect(p.title, 'Upper A');
    expect(p.countdown, isTrue);
    expect(p.when, restStart.add(const Duration(seconds: 90)));
  });

  test('expired rest falls back to elapsed mode', () {
    final restStart = DateTime(2026, 6, 3, 10, 28, 0);
    final p = notificationPayloadFor(
      sessionName: 'Upper A',
      startedAt: started,
      restStart: restStart,
      restTotal: 90, // ended at 10:29:30, now is 10:30
      now: now,
    );
    expect(p.countdown, isFalse);
    expect(p.when, started);
  });

  test('restRevertAt = restStart + restTotal', () {
    expect(
      restRevertAt(DateTime(2026, 1, 1, 10, 0, 0), 90),
      DateTime(2026, 1, 1, 10, 1, 30),
    );
  });

  test('the body names the next exercise, else the given fallback', () {
    expect(
      notificationNextBody('en', 'Bench Press', 'Rest'),
      'Next · Bench Press',
    );
    expect(notificationNextBody('it', 'Panca', 'x'), 'Dopo · Panca');
    expect(
      notificationNextBody('de', 'Bankdrücken', 'x'),
      'Als Nächstes · Bankdrücken',
    );
    expect(
      notificationNextBody('es', 'Press banca', 'x'),
      'Siguiente · Press banca',
    );
    expect(notificationNextBody('en', null, 'Upper A'), 'Upper A');
    expect(notificationNextBody('en', '  ', 'Upper A'), 'Upper A');
    expect(notificationNextBody('zz', 'Row', 'x'), 'Next · Row');
  });

  test('rest-end details alert with vibration, no sound, not only once', () {
    final details = buildRestEndAndroidDetails(
      startedAt: started,
      channelName: 'Rest end',
      channelDescription: 'Synthetic',
    );
    expect(details.channelId, AlkionIdentity.restEndChannel);
    expect(details.channelId, isNot(AlkionIdentity.notificationChannel));
    expect(details.importance, Importance.high);
    expect(details.priority, Priority.high);
    expect(details.playSound, isFalse);
    expect(details.enableVibration, isTrue);
    expect(details.onlyAlertOnce, isFalse);
    expect(details.ongoing, isTrue);
    expect(details.usesChronometer, isTrue);
    expect(details.chronometerCountDown, isFalse);
    expect(details.when, started.millisecondsSinceEpoch);
    expect(details.actions, isNull);
    final quiet = buildWorkoutAndroidDetails(
      countdown: false,
      when: started,
      withAction: false,
      channelName: 'Workout session',
    );
    expect(quiet.importance, Importance.low);
    expect(quiet.onlyAlertOnce, isTrue);
    expect(quiet.playSound, isFalse);
  });

  group('installed plugin v21 method-channel contract', () {
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    late List<MethodCall> calls;
    late bool enabled, exact, denyRequest, failExact, failAll;
    late WorkoutNotification notifier;
    final action = NotificationAction(
      applicationId: AlkionIdentity.applicationId,
      profileId: 'synthetic-profile',
      generation: 1,
      draftId: 'synthetic-draft',
      restStart: DateTime.now().toIso8601String(),
      timerRevision: 1,
      token: 'issued-synthetic-token',
    );
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      calls = [];
      enabled = true;
      exact = true;
      denyRequest = failExact = failAll = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'initialize':
                return true;
              case 'areNotificationsEnabled':
                return enabled;
              case 'requestNotificationsPermission':
                return !denyRequest;
              case 'canScheduleExactNotifications':
                return exact;
              case 'getNotificationAppLaunchDetails':
                return {
                  'notificationLaunchedApp': true,
                  'notificationResponse': {
                    'notificationId': 4101,
                    'actionId': AlkionIdentity.addRestAction,
                    'payload': action.encode(),
                    'notificationResponseType': 1,
                  },
                };
              case 'zonedSchedule':
                final mode =
                    (call.arguments
                        as Map)['platformSpecifics']['scheduleMode'];
                if (failAll ||
                    (failExact &&
                        mode == AndroidScheduleMode.exactAllowWhileIdle.name)) {
                  throw PlatformException(code: 'exact_alarms_not_permitted');
                }
                return null;
              default:
                return null;
            }
          });
      notifier = WorkoutNotification(isAndroid: true);
    });
    tearDown(() async {
      await notifier.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    final workoutStart = DateTime.now().subtract(const Duration(minutes: 5));
    Future<void> show({
      String? next,
      bool alert = false,
      int step = 1,
      bool force = false,
    }) => notifier.showFor(
      name: 'Synthetic',
      startedAt: workoutStart,
      restStart: DateTime.parse(action.restStart!),
      restTotal: 600,
      action: action,
      step: step,
      nextName: next,
      alertAtRestEnd: alert,
      force: force,
    );
    NotificationEnvelope posted(Map<dynamic, dynamic> arguments) =>
        NotificationEnvelope.decode(arguments['payload'] as String)!;
    Map<dynamic, dynamic> last(String method) =>
        calls.lastWhere((c) => c.method == method).arguments as Map;

    test(
      'cold response keeps its payload; the background handler is registered; '
      'two background actions in fixed order; exact schedule and cancel',
      () async {
        final launch = await notifier.init(onResponse: (_) {});
        expect(launch!.payload, action.encode());
        final init =
            calls.firstWhere((c) => c.method == 'initialize').arguments as Map;
        // The plugin's dispatcher and the handler's callback handle: the
        // secondary engine runs onBackgroundNotificationResponse.
        expect(init['dispatcher_handle'], isA<int>());
        expect(init['callback_handle'], isA<int>());
        expect(
          init['callback_handle'],
          PluginUtilities.getCallbackHandle(
            onBackgroundNotificationResponse,
          )!.toRawHandle(),
        );
        await show();
        final shown =
            calls.firstWhere((c) => c.method == 'show').arguments as Map;
        final envelope = posted(shown);
        expect(envelope.action.encode(), action.encode());
        expect(envelope.step, 1);
        expect(envelope.view!.restTotal, 600);
        expect(envelope.view!.title, 'Synthetic');
        final details = shown['platformSpecifics'] as Map;
        final actions = details['actions'] as List;
        expect(
          [for (final a in actions) a['id']],
          [AlkionIdentity.addRestAction, AlkionIdentity.skipRestAction],
        );
        expect(actions[addRestActionIndex]['title'], '+30s');
        expect(actions[skipRestActionIndex]['title'], 'Skip rest');
        for (final a in actions) {
          expect(a['showsUserInterface'], isFalse);
          expect(a['cancelNotification'], isFalse);
        }
        expect(calls.where((c) => c.method == 'zonedSchedule').length, 1);
        await notifier.close();
        final count = calls.length;
        await show();
        expect(calls.length, count);
        expect(calls.last.method, 'cancel');
      },
    );

    test(
      'denial and later revocation cancel mirrors without throwing',
      () async {
        await notifier.init(onResponse: (_) {});
        enabled = false;
        denyRequest = true;
        await show();
        expect(notifier.limitation, NotificationLimitation.denied);
        expect(calls.where((c) => c.method == 'show'), isEmpty);
        enabled = true;
        await show();
        expect(notifier.limitation, isNull);
        enabled = false;
        await show();
        expect(notifier.limitation, NotificationLimitation.denied);
        expect(
          calls.where((c) => c.method == 'requestNotificationsPermission'),
          isEmpty,
          reason: 'showFor never prompts; only the first-start explainer does',
        );
        expect(calls.last.method, 'cancel');
      },
    );

    test(
      'unavailable exact capability uses inexact schedule without a limitation',
      () async {
        exact = false;
        await notifier.init(onResponse: (_) {});
        await show();
        expect(notifier.limitation, isNull);
        final scheduled =
            calls.singleWhere((c) => c.method == 'zonedSchedule').arguments
                as Map;
        expect(
          scheduled['platformSpecifics']['scheduleMode'],
          AndroidScheduleMode.inexactAllowWhileIdle.name,
        );
      },
    );

    test(
      'exact revocation falls back; failed fallback reports unavailable',
      () async {
        await notifier.init(onResponse: (_) {});
        failExact = true;
        await show();
        expect(notifier.limitation, isNull);
        expect(calls.where((c) => c.method == 'zonedSchedule').length, 2);
        final fallback =
            calls.lastWhere((c) => c.method == 'zonedSchedule').arguments
                as Map;
        expect(
          fallback['platformSpecifics']['scheduleMode'],
          AndroidScheduleMode.inexactAllowWhileIdle.name,
        );
        await show();
        expect(notifier.limitation, isNull);
        expect(calls.where((c) => c.method == 'zonedSchedule').length, 2);
        failAll = true;
        await notifier.cancel();
        await show();
        expect(notifier.limitation, NotificationLimitation.unavailable);
        final shown =
            calls.lastWhere((c) => c.method == 'show').arguments as Map;
        expect(shown['platformSpecifics']['chronometerCountDown'], isFalse);
      },
    );

    test('init creates both channels and uses the monochrome glyph', () async {
      notifier.locale = 'de';
      await notifier.init(onResponse: (_) {});
      final init = last('initialize');
      expect(init['defaultIcon'], '@drawable/ic_stat_alkion');
      final channels = {
        for (final c in calls.where(
          (c) => c.method == 'createNotificationChannel',
        ))
          (c.arguments as Map)['id']: c.arguments as Map,
      };
      expect(channels.keys, {
        AlkionIdentity.notificationChannel,
        AlkionIdentity.restEndChannel,
      });
      final quiet = channels[AlkionIdentity.notificationChannel]!;
      expect(quiet['importance'], Importance.low.value);
      expect(quiet['playSound'], isFalse);
      final alert = channels[AlkionIdentity.restEndChannel]!;
      expect(alert['importance'], Importance.high.value);
      expect(alert['playSound'], isFalse);
      expect(alert['enableVibration'], isTrue);
      expect(alert['name'], 'Pausenende');
      expect(alert['description'], isNotEmpty);
    });

    test(
      'rest end uses the alert channel only when the screen is not in front',
      () async {
        await notifier.init(onResponse: (_) {});
        await show(next: 'Bench Press', alert: false);
        var shown = last('show');
        expect(shown['body'], 'Next · Bench Press');
        expect(
          shown['platformSpecifics']['channelId'],
          AlkionIdentity.notificationChannel,
        );
        var scheduled = last('zonedSchedule');
        expect(
          scheduled['platformSpecifics']['channelId'],
          AlkionIdentity.notificationChannel,
        );
        expect(scheduled['title'], 'Synthetic');
        expect(scheduled['body'], 'Workout in progress');
        expect(scheduled['platformSpecifics']['onlyAlertOnce'], isTrue);

        // The screen closes: the same rest is rescheduled as the alert.
        await show(next: 'Bench Press', alert: true);
        expect(calls.where((c) => c.method == 'zonedSchedule').length, 2);
        scheduled = last('zonedSchedule');
        final details = scheduled['platformSpecifics'] as Map;
        expect(details['channelId'], AlkionIdentity.restEndChannel);
        expect(details['importance'], Importance.high.value);
        expect(details['playSound'], isFalse);
        expect(details['enableVibration'], isTrue);
        expect(details['onlyAlertOnce'], isFalse);
        expect(details['ongoing'], isTrue);
        expect(scheduled['id'], 4101);
        expect(scheduled['title'], 'Rest finished');
        expect(scheduled['body'], 'Next · Bench Press');
        expect(scheduled['payload'], last('show')['payload']);
        expect(posted(scheduled).action.encode(), action.encode());
        // The live countdown keeps the quiet channel and both actions.
        shown = last('show');
        expect(
          shown['platformSpecifics']['channelId'],
          AlkionIdentity.notificationChannel,
        );
        expect(
          [
            for (final a in shown['platformSpecifics']['actions'] as List)
              a['id'],
          ],
          [AlkionIdentity.addRestAction, AlkionIdentity.skipRestAction],
        );

        // Nothing pending: the alert names the workout.
        notifier.locale = 'it';
        await show(alert: true);
        scheduled = last('zonedSchedule');
        expect(scheduled['title'], 'Recupero finito');
        expect(scheduled['body'], 'Synthetic');
        expect(last('show')['body'], 'Recupero');
        expect(
          (last('show')['platformSpecifics']['actions']
              as List)[skipRestActionIndex]['title'],
          'Salta recupero',
        );
        expect(
          calls.where((c) => c.method == 'requestNotificationsPermission'),
          isEmpty,
        );
      },
    );

    test(
      'the payload carries the next step; force re-posts an unchanged mirror',
      () async {
        final markers = <String>[];
        await notifier.close();
        notifier = WorkoutNotification(isAndroid: true, trace: markers.add);
        await notifier.init(onResponse: (_) {});
        await show();
        expect(calls.where((c) => c.method == 'show').length, 1);
        await show();
        expect(
          calls.where((c) => c.method == 'show').length,
          1,
          reason: 'an unchanged mirror is not posted again',
        );
        await show(force: true);
        expect(calls.where((c) => c.method == 'show').length, 2);
        await show(step: 2);
        expect(calls.where((c) => c.method == 'show').length, 3);
        expect(posted(last('show')).step, 2);
        expect(posted(last('zonedSchedule')).step, 2);
        expect(markers, [
          'alkion-notif re-rendered issued-s 1',
          'alkion-notif re-rendered issued-s 1',
          'alkion-notif re-rendered issued-s 2',
        ]);
      },
    );

    test('labels Skip rest in all four languages', () {
      final labels = {
        for (final language in ['en', 'it', 'de', 'es'])
          language: workoutNotificationActions(
            language,
          )[skipRestActionIndex].title,
      };
      expect(labels, {
        'en': 'Skip rest',
        'it': 'Salta recupero',
        'de': 'Pause überspringen',
        'es': 'Saltar descanso',
      });
    });

    test('permission is queried and requested only on demand', () async {
      expect(
        await notifier.notificationsEnabled(),
        isNull,
        reason: 'not ready',
      );
      expect(await notifier.requestPermission(), isFalse);
      await notifier.init(onResponse: (_) {});
      enabled = false;
      expect(await notifier.notificationsEnabled(), isFalse);
      expect(
        calls.where((c) => c.method == 'requestNotificationsPermission'),
        isEmpty,
      );
      expect(await notifier.requestPermission(), isTrue);
      denyRequest = true;
      expect(await notifier.requestPermission(), isFalse);
      expect(
        calls.where((c) => c.method == 'requestNotificationsPermission').length,
        2,
      );
    });
  });
}
