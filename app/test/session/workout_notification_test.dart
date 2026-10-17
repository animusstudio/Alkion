import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/session/workout_notification.dart';
import 'package:alkion/session/notification_action.dart';
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
    expect(p.body, 'Workout in progress');
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
    expect(p.body, 'Rest');
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
    expect(p.body, 'Workout in progress');
  });

  test('restRevertAt = restStart + restTotal', () {
    expect(
      restRevertAt(DateTime(2026, 1, 1, 10, 0, 0), 90),
      DateTime(2026, 1, 1, 10, 1, 30),
    );
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
    Future<void> show() => notifier.showFor(
      name: 'Synthetic',
      startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      restStart: DateTime.parse(action.restStart!),
      restTotal: 600,
      action: action,
    );

    test(
      'cold response has fenced payload; visible action only; exact schedule and cancel',
      () async {
        final launch = await notifier.init(onResponse: (_) {});
        expect(launch!.payload, action.encode());
        final init =
            calls.firstWhere((c) => c.method == 'initialize').arguments as Map;
        expect(init, isNot(contains('dispatcher_handle')));
        expect(init, isNot(contains('callback_handle')));
        await show();
        final shown =
            calls.firstWhere((c) => c.method == 'show').arguments as Map;
        expect(shown['payload'], action.encode());
        final details = shown['platformSpecifics'] as Map;
        expect(
          (details['actions'] as List).single['showsUserInterface'],
          isTrue,
        );
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
          calls
              .where((c) => c.method == 'requestNotificationsPermission')
              .length,
          1,
        );
        expect(calls.last.method, 'cancel');
      },
    );

    test(
      'unavailable exact capability uses inexact schedule and reports delay',
      () async {
        exact = false;
        await notifier.init(onResponse: (_) {});
        await show();
        expect(notifier.limitation, NotificationLimitation.inexact);
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
        expect(notifier.limitation, NotificationLimitation.inexact);
        expect(calls.where((c) => c.method == 'zonedSchedule').length, 2);
        await show();
        expect(notifier.limitation, NotificationLimitation.inexact);
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
  });
}
