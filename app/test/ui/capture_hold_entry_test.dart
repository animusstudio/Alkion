// The capture feature as the running app reaches it: the Profile → Data
// capture row through the app-wide provider, the live workout's notice
// while a capture holds the source, and new workouts refused during a hold.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:workout_tracker/auth/auth_store.dart';
import 'package:workout_tracker/capture/capture_coordinator.dart';
import 'package:workout_tracker/capture/capture_export.dart';
import 'package:workout_tracker/capture/capture_service.dart';
import 'package:workout_tracker/session/active_session_controller.dart';
import 'package:workout_tracker/session/active_session_screen.dart';
import 'package:workout_tracker/session/session_manager.dart';
import 'package:workout_tracker/shell/session_launcher.dart';
import 'package:workout_tracker/ui/capture_screen.dart';
import 'package:workout_tracker/ui/profile_screen.dart';

import '../support/screen_harness.dart';

class _Backend implements CaptureBackend {
  final calls = <String>[];

  @override
  bool get canCapture => true;
  @override
  bool get canExportToDirectory => true;

  @override
  Future<CaptureView> inspect() async {
    calls.add('inspect');
    return const CaptureView(code: 'none');
  }

  @override
  Future<CaptureView> capture(CaptureMode mode) async =>
      const CaptureView(code: 'none');
  @override
  Future<CaptureView> resumeOriginal(String captureId) async =>
      const CaptureView(code: 'none');
  @override
  Future<ExportAttempt> exportToDirectory(Directory parent,
          {ExportCancellation? cancellation}) async =>
      const ExportAttempt(
          manifestSha256: '', transportStatus: ExportTransportStatus.failed);
}

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets('the Profile row opens Data capture through the app provider',
      (tester) async {
    await harness.open(tester);
    setPhone(tester, width: 412);
    final backend = _Backend();
    final service = CaptureService(backend);
    // As main.dart provides it: above the app, a ChangeNotifierProvider.
    await tester.pumpWidget(harness.wrap(
      ProfileScreen(onClose: () {}, onLogout: () async {}, auth: AuthStore()),
      extra: [ChangeNotifierProvider<CaptureService>.value(value: service)],
    ));
    await settleReal(tester);
    final row = find.text('Data capture');
    await scrollIntoView(tester, find.byType(ProfileScreen), row);
    await tester.tap(row);
    await settleReal(tester, ticks: 10);
    expect(tester.takeException(), isNull);
    expect(find.byType(CaptureScreen), findsOneWidget);
    expect(backend.calls, ['inspect']);
    expect(find.text('No capture yet'), findsOneWidget);
    await harness.unmount(tester);
  });

  testWidgets('the live workout says its changes are not saved while held',
      (tester) async {
    await harness.open(tester);
    setPhone(tester, width: 412);
    final controller = ActiveSessionController()..seedForTest(longDraft());
    await tester.pumpWidget(harness.wrap(
      const ActiveSessionScreen(),
      extra: [
        ChangeNotifierProvider<ActiveSessionController>.value(
            value: controller),
      ],
    ));
    await settleReal(tester, ticks: 5);
    final banner = find.byKey(const Key('capture-hold-banner'));
    expect(banner, findsNothing);

    controller.freezeCallbacks(1);
    await settleReal(tester, ticks: 2);
    expect(banner, findsOneWidget);
    expect(
        find.textContaining("changes to this workout aren't being saved"),
        findsOneWidget);
    expect(find.textContaining('lost if the app closes'), findsOneWidget);

    controller.resumeCallbacks(DateTime.now());
    await settleReal(tester, ticks: 2);
    expect(banner, findsNothing);
    await harness.unmount(tester);
  });

  testWidgets('a new or resumed workout is refused during a hold',
      (tester) async {
    await harness.open(tester);
    setPhone(tester, width: 412);
    late SessionManager manager;
    await tester.pumpWidget(harness.wrap(Scaffold(
      body: Builder(builder: (context) {
        manager = context.read<SessionManager>();
        return Column(children: [
          TextButton(
              onPressed: () => startSession(context),
              child: const Text('start')),
          TextButton(
              onPressed: () => resumeFinishedSession(context, 'session-1'),
              child: const Text('resume')),
        ]);
      }),
    )));
    await settleReal(tester, ticks: 2);
    manager.freezeCallbacks(1);

    for (final action in const ['start', 'resume']) {
      await tester.tap(find.text(action));
      await settleReal(tester, ticks: 3);
      expect(find.text('Paused for data capture'), findsOneWidget,
          reason: action);
      expect(find.textContaining("a new workout can't start now"),
          findsOneWidget);
      expect(manager.hasActive, isFalse);
      await tester.tap(find.text('OK'));
      await settleReal(tester, ticks: 3);
    }

    manager.resumeCallbacks(DateTime.now(), generation: 1);
    await harness.unmount(tester);
  });
}
