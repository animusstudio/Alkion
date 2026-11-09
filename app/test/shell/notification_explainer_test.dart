import 'package:alkion/session/workout_notification.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/shell/notification_explainer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/l10n_harness.dart';

/// The explainer over the installed plugin's method channel (the
/// `workout_notification_test.dart` pattern) and an in-memory settings
/// service; persistence of the flag is covered by the real SQLite test in
/// `test/settings/settings_test.dart`.
void main() {
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  late List<String> calls;
  late bool enabled;
  late WorkoutNotification notifier;
  late SettingsService settings;
  late Future<void>? running;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls = [];
    enabled = false;
    running = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'initialize' => true,
            'areNotificationsEnabled' => enabled,
            'requestNotificationsPermission' => true,
            _ => null,
          };
        });
    notifier = WorkoutNotification(isAndroid: true);
    await notifier.init(onResponse: (_) {});
    debugDefaultTargetPlatformOverride = null;
    settings = SettingsService();
    calls.clear();
  });
  tearDown(() async {
    await notifier.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  // The plugin resolves its Android implementation by target platform.
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  Future<void> mount(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    WorkoutNotification? using,
  }) async {
    await tester.pumpWidget(
      wrapL10n(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => running = explainNotificationsOnce(
              context,
              notifier: using ?? notifier,
              settings: settings,
            ),
            child: const Text('start'),
          ),
        ),
        locale: locale,
      ),
    );
    await tester.tap(find.text('start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  int requests() =>
      calls.where((c) => c == 'requestNotificationsPermission').length;

  testWidgets('continuing explains once, then prompts', (tester) async {
    await mount(tester);
    expect(
      find.text(
        'Alkion shows your rest timer in a notification and vibrates when rest ends.',
      ),
      findsOneWidget,
    );
    expect(requests(), 0, reason: 'no prompt before the user continues');
    await tester.tap(find.text('Continue'));
    await tester.pump(const Duration(milliseconds: 400));
    await running;
    expect(requests(), 1);
    expect(settings.notificationsExplained, isTrue);

    // Remembered: a later start shows nothing and prompts nothing.
    await tester.tap(find.text('start'));
    await tester.pump(const Duration(milliseconds: 400));
    await running;
    expect(find.text('Continue'), findsNothing);
    expect(requests(), 1);
  }, variant: android);

  testWidgets('declining never prompts and is remembered', (tester) async {
    await mount(tester, locale: const Locale('it'));
    expect(find.text('Notifiche del recupero'), findsOneWidget);
    await tester.tap(find.text('Non ora'));
    await tester.pump(const Duration(milliseconds: 400));
    await running;
    expect(requests(), 0);
    expect(settings.notificationsExplained, isTrue);
    await tester.tap(find.text('start'));
    await tester.pump(const Duration(milliseconds: 400));
    await running;
    expect(find.text('Non ora'), findsNothing);
    expect(requests(), 0);
  }, variant: android);

  testWidgets('already granted: nothing appears', (tester) async {
    enabled = true;
    await mount(tester);
    await running;
    expect(find.text('Continue'), findsNothing);
    expect(find.text('Rest timer notifications'), findsNothing);
    expect(requests(), 0);
    expect(calls, contains('areNotificationsEnabled'));
  }, variant: android);

  testWidgets('unsupported platform: nothing appears', (tester) async {
    await mount(tester, using: WorkoutNotification(isAndroid: false));
    await running;
    expect(find.text('Continue'), findsNothing);
    expect(calls, isEmpty);
  }, variant: android);
}
