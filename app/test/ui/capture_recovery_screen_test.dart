import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workout_tracker/capture/capture_startup.dart';
import 'package:workout_tracker/l10n/app_localizations.dart';
import 'package:workout_tracker/ui/capture_recovery_screen.dart';

import '../support/l10n_harness.dart';

void main() {
  for (final locale in const [
    Locale('en'),
    Locale('de'),
    Locale('it'),
    Locale('es'),
  ]) {
    testWidgets('held startup is readable and shows only a safe code '
        '(${locale.languageCode})', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(wrapL10n(
        const CaptureRecoveryScreen(
          recovery: CaptureRecoveryState(
            code: 'capture_active',
            stage: 'local_hold',
            captureId: '3f1c2a4e-8b7d-4c6a-9e2f-1a2b3c4d5e6f',
          ),
        ),
        locale: locale,
      ));
      expect(find.textContaining('capture_active · local_hold'),
          findsOneWidget);
      // The capture id is not personal data, but it is not shown either.
      expect(find.textContaining('3f1c2a4e'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('english wording', (tester) async {
    await tester.pumpWidget(wrapL10n(const CaptureRecoveryScreen(
      recovery: CaptureRecoveryState(code: 'journal_unknown_version'),
    )));
    expect(find.text('Capture not finished'), findsOneWidget);
    expect(find.text('Status: journal_unknown_version'), findsOneWidget);
  });

  testWidgets('a failed safety copy says so', (tester) async {
    await tester.pumpWidget(wrapL10n(const CaptureRecoveryScreen(
      recovery: CaptureRecoveryState(code: 'preservation_failed'),
    )));
    expect(find.textContaining('could not make a safety copy'),
        findsOneWidget);
    expect(find.textContaining('found a data capture'), findsNothing);
    expect(find.text('Workouts not opened'), findsOneWidget);
    expect(find.text('Capture not finished'), findsNothing);
  });

  for (final code in const [
    'preservation_failed',
    'gate_busy',
    'gate_io_error',
  ]) {
    testWidgets('$code offers try again, which re-runs startup at once',
        (tester) async {
      var runs = 0;
      final run = Completer<void>();
      await tester.pumpWidget(wrapL10n(CaptureRecoveryScreen(
        recovery: CaptureRecoveryState(code: code),
        onResolved: () {
          runs++;
          return run.future;
        },
      )));
      expect(find.text('Try again'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(runs, 1);
      // No confirmation is asked, and a second tap while startup runs again
      // does not start another run.
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(runs, 1);
      run.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(runs, 2);
    });
  }

  testWidgets('holds that need a decision offer no try again', (tester) async {
    for (final recovery in const [
      CaptureRecoveryState(code: 'capture_active', stage: 'local_hold'),
      CaptureRecoveryState(code: 'capture_interrupted', stage: 'held'),
      CaptureRecoveryState(code: 'journal_unknown_version'),
    ]) {
      await tester.pumpWidget(wrapL10n(CaptureRecoveryScreen(
        key: ValueKey(recovery.code),
        recovery: recovery,
        onResolved: () async {},
      )));
      expect(find.text('Try again'), findsNothing, reason: recovery.code);
    }
    // Without a way to run startup again, nothing is offered either.
    await tester.pumpWidget(wrapL10n(const CaptureRecoveryScreen(
      recovery: CaptureRecoveryState(code: 'gate_busy'),
    )));
    expect(find.text('Try again'), findsNothing);
  });

  for (final locale in const [
    Locale('en'),
    Locale('de'),
    Locale('it'),
    Locale('es'),
  ]) {
    testWidgets('try again is localized (${locale.languageCode})',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(wrapL10n(
        CaptureRecoveryScreen(
          recovery: const CaptureRecoveryState(code: 'gate_io_error'),
          onResolved: () async {},
        ),
        locale: locale,
      ));
      final label = lookupAppLocalizations(locale).captureRecoveryRetry;
      expect(find.text(label), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
