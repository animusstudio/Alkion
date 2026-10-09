import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workout_tracker/capture/capture_startup.dart';
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
}
