import 'dart:async';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/notification_action.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/session/workout_notification.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../alkion/domains/local_screen_harness.dart';
import '../support/app_fonts.dart';

/// An Android notifier whose permission is off; records what the launcher
/// asks of it. Mirrors are recorded, not posted.
class _OffNotifier extends WorkoutNotification {
  _OffNotifier() : super(isAndroid: true);
  int requests = 0, shows = 0;
  @override
  Future<bool?> notificationsEnabled() async => false;
  @override
  Future<bool> requestPermission() async {
    requests++;
    return false;
  }

  @override
  Future<NotificationResponse?> init({
    required void Function(NotificationResponse) onResponse,
  }) async => null;
  @override
  Future<void> showFor({
    required String name,
    required DateTime startedAt,
    DateTime? restStart,
    int restTotal = 0,
    NotificationAction? action,
    String? nextName,
    bool alertAtRestEnd = false,
  }) async => shows++;
  @override
  Future<void> cancel() async {}
}

void main() {
  setUpAll(preloadAppFonts);

  testWidgets(
    'the explainer comes after admission and before the workout opens, once',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      late SessionManager manager;
      await tester.runAsync(() async {
        manager = SessionManager(draftStore: DraftStore.local(h.localDatabase));
      });
      final notifier = _OffNotifier();
      manager.notifier = notifier;
      addTearDown(() => manager.active?.dispose());
      addTearDown(manager.dispose);
      await tester.pumpWidget(
        h.wrap(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => unawaited(startSession(context)),
                child: const Text('Start'),
              ),
            ),
          ),
          extra: [ChangeNotifierProvider<SessionManager>.value(value: manager)],
        ),
      );
      await tester.tap(find.text('Start'));
      await settleReal(tester, ticks: 8);
      expect(find.text('Rest timer notifications'), findsOneWidget);
      expect(manager.hasActive, isFalse, reason: 'nothing registered yet');
      expect(find.byType(ActiveSessionScreen), findsNothing);
      expect(notifier.shows, 0);

      await tester.tap(find.text('Not now'));
      await settleReal(tester, ticks: 12);
      expect(notifier.requests, 0);
      expect(manager.hasActive, isTrue, reason: 'declining starts normally');
      expect(find.byType(ActiveSessionScreen), findsOneWidget);
      expect(h.settings.notificationsExplained, isTrue);
      await tester.runAsync(h.settings.flushPersistence);
      final reloaded = SettingsService.local(h.localDatabase);
      await tester.runAsync(reloaded.load);
      expect(reloaded.notificationsExplained, isTrue);

      // A later start (here: reopening the running workout) never asks again.
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settleReal(tester);
      await tester.tap(find.text('Start'));
      await settleReal(tester, ticks: 8);
      expect(find.text('Rest timer notifications'), findsNothing);
      expect(find.byType(ActiveSessionScreen), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settleReal(tester);
      await tester.runAsync(() => manager.active!.discard());
      await h.unmount(tester);
    },
  );
}
